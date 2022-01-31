#!/bin/bash

cat >data <<EOF
This is some data to test signing a file with the firmware signing key/cert.
EOF

CA_BUNDLE="./firmware-signing/ca-bundle.crt"
KEY="./firmware-signing/firmware-signing.key"
CRT="./firmware-signing/firmware-signing.crt"
PUB="./firmware-signing/firmware-signing.pub"

set -x

# Verify the certificate
openssl verify -CAfile ${CA_BUNDLE} -show_chain ${CRT}

# Get the public key
openssl x509 -pubkey -noout -in ${CRT} -out ${PUB}

# Generate signature
openssl dgst -sha256 -sign ${KEY} -out data.sig data

# Verify signature
openssl dgst -sha256 -verify ${PUB} -signature data.sig data

# Modify file and reverify (should fail)
echo "Modified" >> data
openssl dgst -sha256 -verify ${PUB} -signature data.sig data
