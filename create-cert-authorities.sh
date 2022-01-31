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
	commonName              = ${FULL_CORP} Root CA
	countryName             = ${COUNTRY}
	stateOrProvinceName     = ${STATE}
	localityName            = ${CITY}
	organizationName        = ${FULL_CORP}
	organizationalUnitName  = ${ORG_UNIT}

	[ v3_ca ]
	subjectKeyIdentifier=hash
	basicConstraints=critical,CA:true,pathlen:1
	keyUsage=critical,keyCertSign,cRLSign
	nameConstraints=critical,@nc

	[ nc ]
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

    openssl ecparam -name secp384r1 -genkey -noout -out ${CA_KEY} \
        || exit 1

    # NOTE: You might need to 'apt install datefudge'.
    datefudge "2020-01-01 UTC" openssl req -new -sha256 -x509 \
        -set_serial 1 -days 1000000 -config ${OPENSSL_CONF} \
        -key ${CA_KEY} -out ${CA_CRT} \
        || exit 1

    echo 01 > ${CA_SERIAL}

    openssl x509 -noout -text -in ${CA_CRT}
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
        openssl ecparam -name secp384r1 -genkey -noout -out ${SUB_CA_KEY} \
            || return 1

        # Generate the Sub-CA certificate signing request.
        openssl req -sha256 -new -config ${SUB_CA_CSR_CFG} \
            -key ${SUB_CA_KEY} -nodes -out ${SUB_CA_CSR} \
            || return 1

        # Generate the Sub-CA certificate.
        openssl x509 -sha256 -CA ${CA_CRT} -CAkey ${CA_KEY} -days 5500 -req \
            -in ${SUB_CA_CSR} -extfile ${SUB_CA_CRT_CFG} -out ${SUB_CA_CRT} \
            || return 1

        echo 00 > ${SUB_CA_SERIAL}

        openssl x509 -noout -text -in ${SUB_CA_CRT}
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

    YK_SETUP="${OUTDIR}/yubikey-${user}-setup.sh"
    YKMAN="ykman --device ${user##*-}"

    cat >${YK_SETUP} <<-EOF
	#!/bin/bash -x
	#
	# Configure Yubikey PIV with SuB CA key/cert: ${user}
	#

	# Reset the PIV application
	if [ "\$1" == "reset" ]; then
	    ${YKMAN} piv reset || exit 1
	fi

	# Set acccess codes.
	${YKMAN} piv access change-management-key -n ${key} || exit 1
	${YKMAN} piv access change-pin -P 123456 -n ${pin} || exit 1
	${YKMAN} piv access change-puk -p 12345678 -n ${puk} || exit 1

	# Load Sub CA private key and certificates
	${YKMAN} piv keys import 9c ${SUB_CA_KEY} -m ${key}
	${YKMAN} piv certificates import 9c ${SUB_CA_CRT} -m ${key}
	${YKMAN} piv certificates import 82 ${CA_CRT} -m ${key}

	${YKMAN} piv info
	EOF
    chmod 755 ${YK_SETUP}
    echo "Yubiky setup script: ${YK_SETUP}"
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
