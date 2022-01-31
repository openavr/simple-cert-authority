#!/bin/bash
#
# Script to use the Yubikey Sub-CA to create and sign a firmware signing
# certificate.
#

function confirm_yes_no () {
    printf "%s [y/N]: " "$1"
    read ans junk
    case "${ans}" in
        y*|Y*)
            ;;
        *)
            echo "Good Bye!"
            return 1
            ;;
    esac
    return 0
}

ykman piv info || exit 1
echo

confirm_yes_no "Is the above output what you expect from the Yubikey?" \
    || exit 1

unset hostname
while /bin/true
do
    printf "\nPlease enter the hostname of the firmware signing system.\n"
    printf "For example: 'build-server.example.com'\n"
    printf ">>>> "
    read hostname junk

    printf "\nYou entered: ${hostname}\n"
    confirm_yes_no "Is this correct?" && break
done

mkdir -p firmware-signing
pushd firmware-signing

# Extract the Root CA cert from the Yubikey
ykman piv export-certificate 82 ca.crt

# Extract the Sub CA cert from the Yubikey
ykman piv export-certificate 9c sub-ca.crt
openssl x509 -pubkey -noout -in sub-ca.crt > sub-ca.pub
test -f sub-ca.srl || echo 01 > sub-ca.srl

cat sub-ca.crt ca.crt > ca-bundle.crt

openssl verify -CAfile ca.crt sub-ca.crt || exit 1

cat >firmware-signing-crt.conf <<EOF
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectAltName   = critical,DNS:${hostname}
EOF

cat >firmware-signing-csr.conf <<EOF
[ req ]
distinguished_name = req_dn
prompt = no

[ req_dn ]
CN=${hostname}
EOF

set -x

openssl ecparam -name secp384r1 -genkey -noout -out firmware-signing.key \
    || return 1

openssl req -sha256 -new \
    -config firmware-signing-csr.conf \
    -key firmware-signing.key \
    -nodes \
    -out firmware-signing.csr \
    || exit 1

cat >openssl-yubikey.conf <<EOF
openssl_conf     = openssl_def

[openssl_def]
engines          = engine_section

[engine_section]
pkcs11           = pkcs11_section

[pkcs11_section]
engine_id        = pkcs11
dynamic_path     = /usr/lib/x86_64-linux-gnu/engines-1.1/libpkcs11.so
MODULE_PATH      = /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so
EOF

OPENSSL_CONF=openssl-yubikey.conf openssl x509 \
    -engine pkcs11 \
    -CAkeyform engine \
    -CAkey slot_0-id_2 -sha256 \
    -CA sub-ca.crt \
    -req \
    -in firmware-signing.csr \
    -extfile firmware-signing-crt.conf \
    -out firmware-signing.crt \
    || exit 1

openssl verify -show_chain -CAfile ca-bundle.crt firmware-signing.crt
