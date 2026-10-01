#!/bin/bash
# One-time: creates a self-signed code-signing certificate named "MacLinker Dev" in your login keychain.
# Signing every release with the same certificate is what lets macOS keep the Accessibility /
# Input Monitoring grants across updates, and lets MacLinker verify that an update came from you.
# Back up the certificate (Keychain Access > export): if you lose it, updates can't be verified.
set -euo pipefail
NAME="MacLinker Dev"
KC="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then echo "'$NAME' already exists."; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$T/k.pem" -out "$T/c.pem" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/k.p12" -passout pass:maclinker -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
security import "$T/k.p12" -k "$KC" -P maclinker -T /usr/bin/codesign >/dev/null
# Trust it for code signing (macOS will ask for your login password).
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$T/c.pem"
echo "Created '$NAME'."
