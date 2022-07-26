# Self Signed Certificate Authority

This project automates to following tasks:

* Setting up a self signed certificate authority

  + Generate Private Key for CA
  + Generate CA Certificate

* Creating multiple Sub CA Key/Cert
* Creating data needed to import the Sub CA Key/Cert into a Yubikey

I'm not trying to promote Yubikeys with this project. I just want to document
how I configure and use the Yubikeys that I own.

## Setup

Before you start, you need to install some things on your system:

* `openssl`
* `datefudge`
* `yubico-piv-tool` (obsolete: use `ykman` instead)
* `yubikey-manager` (installs the `ykman` CLI tool)
* `yubikey-manager-qt` (optional GUI)

## Usage

Start with configuring the CA and the Sub CA users:

    $ cp ca.cfg.template ca.cfg
    $ ${EDITOR} ca.cfg

It is recommended that you start with a single Sub-CA user and Yubikey to test
things out.

Once you have configured the CA, run the script to generate the CA output:

    $ ./create-cert-authorities.sh

Follow the instructions in the output to program a Sub CA key and certificate
into a Yubikey.

**NOTE:** The instructions show installing the CA Certificate into slot 82 of
the Yubikey. This only installs the public Certificate, not the Private key.
**Do NOT install the CA Private key into the Yubikey.** The CA certificate is
installed so that you can always have access to the root CA certificate for
validating the full chain of trust of certificates signed by the Sub CA.

## Protect the CA Private Key

The CA private key is not encrypted or passphrase protected. If you are serious
about the security of the CA private key, you should only use it on a secure
computer (preferably one without network connectivity).

The generated private keys, certificates and Yubikey access codes should not be
committed to this repository. You should securely store and back them up though
so that they can be used to create new Sub-CA key/certs if needed.

## Using the Yubikey Sub-CA to Sign Files

Use the `yubico-piv-tool` to sign files:

    $ yubico-piv-tool -a verify-pin --sign -s 9c -H SHA256 -A RSA2048 \
        -i data.txt -o data.sig

## Verifying Signed Files

Exract the CA and Sub CA certificates from the Yubikey:

    $ ykman piv export-certificate 82 ca.crt
    $ ykman piv export-certificate 9c sub-ca.crt

Examine the certificates:

    $ openssl x509 -text -in ca.crt
    $ openssl x509 -text -in sub-ca.crt

Use the CA certificate to verify the Sub-CA certificate:

    $ openssl verify -CAfile ca.crt sub-ca.crt

Once you have verified the Sub-CA certificate, you need to extract the Sub-CA
public key from the certificate:

    $ openssl x509 -pubkey -noout -in sub-ca.crt > sub-ca.pub

Verify the signed file with the Sub CA public key:

    $ openssl dgst -sha256 -verify sub-ca.pub -signature data.sig data.txt

## Signing and Verifying Firmware Update Files

Now we get to the end game of all of this...

I develop firmware images for various Single Board Computers (SBC) using Yocto.
I want to be able to trust those images before they are loaded on the devices
(e.g. OTA updates), so I need to be able to sign the images at build time and
then verify the signature on the device.

It's not feasible to use the Yubikey Sub CA to sign the images at build time
(due to wanting to have an automated process), so I want to use the Yubikey to
create a signing key and associated certificate to be used by the build system.

### Generating the Signing Key and Certificate

Use the supplied script to create the firmware signing key and certificate:

    $ ./create-firmware-crt.sh

### Using the Signing Key and Certificate

Sign a firmware image:

    $ openssl dgst -sha256 -sign firmware-signing.key -out data.sig data

Verify the image signature:

    $ openssl x509 -pubkey -noout -in firmware-signing.crt \
        -out firmware-signing.pub
    $ openssl dgst -sha256 -verify firmware-signing.pub \
        -signature data.sig data

## References

* https://developers.yubico.com/PIV/Guides/Certificate_authority.html
* https://www.yubico.com/
* https://www.openssl.org/docs/man1.1.1/man5/x509v3_config.html
* https://colinpaice.blog/2021/03/08/using-openssl-with-an-hsm-keystore-and-opensc-pkcs11-engines/
* https://blog.benjojo.co.uk/post/tls-https-server-from-a-yubikey
* https://cromwell-intl.com/cybersecurity/yubikey/

## PKCS#11 Information

### Useful Tools and Commands

`pkcs11-tool`:

    $ pkcs11-tool -O
    $ pkcs11-tool -M

## Private Keys, Public Keys and Certificates Explained

Quick and dirty refresher discussion about PKI

### Key Pairs

#### Private Keys

* *Do Not Share!*
* Must be kept secret and secured.
* 1-to-1 relationship with a public key (forming a key pair).

For CA private keys:

* Should be created and only used on a secure system.

  + Trusted OS installation.
  + No network access.
  + Restricted physical access.

PKCS#11 devices (e.g. a Yubikey) can allow access to the private key
functionality without exposing them directly.

#### Public Keys

* Can be freely shared.
* 1-to-1 relationship with a private key (forming a key pair).

### Certificates

* Can be freely shared.
* Contains a Public key.
* Is signed by a trusted signer (e.g. a CA or a SUB-CA).
* Can be verified if you trust the signer.
* Used with a chain of trust to verify signatures.

  + Root CA signs SUB-CA cert, which signs User cert.
  + If I trust Root CA cert, then I implicitly trust any cert signed by it,
    and thus trust any cert signed by those certs.
  + There are usually limits applied at the root level as to how long the chain
    can be.

* You usually need to extract the public key from a certificate before you can
  use it to verify a signature generated with the associated private key.

### Certificate Authorities

* Sub CA certs are also called intermediary certificates.
* A Sub CA can handle CSR (Certificate Signing Requests) on behalf of the
  Certificate Authority.

## Setup Virtual Machine for running Root CA

Install the latest Debian in a Virtual Machine:

* No GUI or desktop environment.
* Encrypted Root FS

After initial installation complete:

* Install the following packages with `apt install`:

  + yubikey-manager
  + opensc-pkcs11
  + libyubikey-udev
  + ykcs11
  + datefudge
  + git

* Clone this git repository:

      $ mkdir ~/root-ca
      $ cd ~/root-ca
      $ git clone https://github.com/openavr/simple-cert-authoriry.git

* Disconnect the Root CA Virtual Machine from all networks. Network
  access is no longer needed.

* Configure the CA:

      $ cd ~/root-ca/simple-cert-authority
      $ cp ca.cfg.template ca.cfg
      $ ${EDITOR} ca.cfg

* Generate the Root CA and Sub CA data:

      $ ./create-cert-authority

* Run the yubikey setup scripts mentioned in the output from running the
  `create-cert-authority` script. This will program the certs and private key for
  a Sub CA into the Yubikey. Each Yubikey should be programmed with a key/cert
  pair.

* Once you have programmed the Yubikey devices, you will need to store the PIV
  PIN/PUK access codes so that you can use the Yubikey Sub CA devices for signing
  operations.

* Now that you have the programmed the Yubikey Sub CA devices and stored the
  PIN/PUK codes away, you are effectively done with the Root CA virtual machine.
  You can shut it down and store away the VM image for later use (e.g. Sub CA
  cert maintenance, creating new Sub CA certs, cert revocation, etc).

* Note that the Root CA private key has never left the virtual machine. You can
  make a copy of the root ca virtual machine image as a backup and secure it.

* Don't forget the passphrase for unlocking the virtual machine root fs!
