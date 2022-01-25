#!/bin/bash
#
# Script for setting up keys and certificates for having multiple Sub-CA
# signers on multiple Yubikey devices with a common self-signed CA.
#
# The generated CA keys and certificate need to be kept secure.
#
# References:
#
# * https://developers.yubico.com/PIV/Guides/Certificate_authority.html
#

if [ ! -e ./ca.cfg ]
then
    echo "You need to configure your CA information."
    echo "Please copy './ca.cfg.template' to './ca.cfg' and edit it."

    exit 1
fi

source ./ca.cfg

# Convert FULL_CORP to lower case.
CORP="${FULL_CORP,,}"
DOMAIN="${CORP}.${ROOT_DOMAIN}"

BASE=$(pwd)/ca-output-${DOMAIN}

CA_CRT="${BASE}/${DOMAIN}-ca-crt.pem"
CA_SERIAL="${BASE}/${DOMAIN}-ca-crt.srl"
CA_KEY="${BASE}/${DOMAIN}-ca-key.pem"

OPENSSL_CONF="${BASE}/${DOMAIN}-ca.conf"

export LC_CTYPE=C

function create_CA_keys () {
    if [ -e ${CA_KEY} ]
    then
        echo "The CA key already exists: ${CA_KEY}"
        return
    fi

    cat >${OPENSSL_CONF} <<-EOF
	[ req ]
	x509_extensions = v3_ca
	distinguished_name = req_distinguished_name
	prompt = no

	[ req_distinguished_name ]
	CN=${FULL_CORP} CA

	[ v3_ca ]
	subjectKeyIdentifier=hash
	basicConstraints=critical,CA:true,pathlen:1
	keyUsage=critical,keyCertSign,cRLSign
	nameConstraints=critical,@nc

	[ nc ]
	permitted;otherName=1.3.6.1.5.5.7.8.7;IA5:${DOMAIN}
	permitted;email.0=${DOMAIN}
	permitted;email.1=.${DOMAIN}
	permitted;DNS=${DOMAIN}
	permitted;URI.0=${DOMAIN}
	permitted;URI.1=.${DOMAIN}
	permitted;IP.0=0.0.0.0/255.255.255.255
	permitted;IP.1=::/ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
	EOF

    #
    # Generate the CA private key and certificate.
    #

    openssl genrsa -out ${CA_KEY} 2048 || exit 1

    # NOTE: You might need to 'apt install datefudge'.
    datefudge "2020-01-01 UTC" openssl req -new -sha256 -x509 \
        -set_serial 1 -days 1000000 -config ${OPENSSL_CONF} \
        -key ${CA_KEY} -out ${CA_CRT} || exit 1

    echo 01 > ${CA_SERIAL}
}


#
# Function for creating Sub-CA keys and certificate.
#
function create_sub_ca () {
    user="${1}"

    OUTDIR="${BASE}/sub-ca-${user}"
    mkdir -p ${OUTDIR}

    SUB_CA_KEY="${OUTDIR}/sub-ca-${user}-key.pem"
    SUB_CA_CSR_CFG="${OUTDIR}/sub-ca-${user}-csr.conf"
    SUB_CA_CRT_CFG="${OUTDIR}/sub-ca-${user}-crt.conf"
    SUB_CA_CSR="${OUTDIR}/sub-ca-${user}-csr.pem"
    SUB_CA_CRT="${OUTDIR}/sub-ca-${user}-crt.pem"
    SUB_CA_SERIAL="${OUTDIR}/sub-ca-${user}-crt.srl"

    echo "###############################################################"
    echo "# Generating: sub-ca for ${user}"
    echo "###############################################################"

    if [ -e ${SUB_CA_KEY} ]
    then
        echo "Sub-CA Key already exists: ${SUB_CA_KEY}"
    else
        cat >${SUB_CA_CSR_CFG} <<-EOF
		[ req ]
		distinguished_name = req_distinguished_name
		prompt = no

		[ req_distinguished_name ]
		CN=${FULL_CORP} ${user} Sub-CA
		EOF

        cat >${SUB_CA_CRT_CFG} <<-EOF
		basicConstraints = critical, CA:true, pathlen:0
		keyUsage=critical, keyCertSign
		EOF

        # Generate the private key.
        openssl genrsa -out ${SUB_CA_KEY} 2048 || return 1

        # Generate the Sub-CA certificate signing request.
        openssl req -sha256 -new -config ${SUB_CA_CSR_CFG} \
            -key ${SUB_CA_KEY} -nodes -out ${SUB_CA_CSR} || return 1

        # Generate the Sub-CA certificate.
        openssl x509 -sha256 -CA ${CA_CRT} -CAkey ${CA_KEY} -days 5500 -req \
            -in ${SUB_CA_CSR} -extfile ${SUB_CA_CRT_CFG} -out ${SUB_CA_CRT} \
            || return 1

        echo 00 > ${SUB_CA_SERIAL}
    fi

    #
    # Generate random Management Key, PIN and PUK codes to secure PIV access
    # to a yubikey.
    #

    YK_OUTFILE="${OUTDIR}/yubikey-${user}.cfg"

    if [ ! -e ${YK_OUTFILE} ]
    then
		key=$(dd if=/dev/urandom | tr -d '[:lower:]' | tr -cd '[:xdigit:]' \
		      | fold -w48 | head -1)
		pin=$(dd if=/dev/urandom | tr -cd '[:digit:]' | fold -w6 | head -1)
		puk=$(dd if=/dev/urandom | tr -cd '[:digit:]' | fold -w8 | head -1)

        cat >${YK_OUTFILE} 2>/dev/null <<-EOF
		key=${key}
		pin=${pin}
		puk=${puk}
		EOF
    else
        echo "Skipping re-creation of ${YK_OUTFILE}"
    fi

    source ${YK_OUTFILE}

    cat <<-EOF

	Run the following commands to configure the Yubikey PIV access codes:

	$ ykman piv change-management-key -n ${key}
	$ ykman piv change-pin -P 123456 -n ${pin}
	$ ykman piv change-puk -p 12345678 -n ${puk}

	Run the following commands to import the Sub-CA private key and certificate
	into the Yubikey:

	$ ykman piv import-key 9c ${SUB_CA_KEY} -m ${key}
	$ ykman piv import-certificate 9c ${SUB_CA_CRT} -m ${key}
	$ ykman piv import-certificate 82 ${CA_CRT} -m ${key}
	EOF
}

#
# Main
#

mkdir -p ${BASE}

create_CA_keys

for user in ${SUB_CA_USERS[@]}
do
    create_sub_ca ${user}
done
