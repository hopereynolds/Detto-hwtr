#!/usr/bin/env bash
set -euo pipefail

# Create a self-signed code-signing certificate in the login keychain.
#
# macOS ties Microphone and Screen Recording permissions to an app's signing
# certificate. Ad-hoc builds get a new identity every time, so permissions are
# asked for again after each rebuild. Signing every build with this one
# certificate keeps them. It's for local builds only: it isn't trusted by
# other Macs and can't be notarized.
#
# Usage: ./scripts/setup_local_signing.sh ["Certificate Name"]

NAME="${1:-Detto HWTR Local Signing}"

if security find-identity -p codesigning | grep -Fq "\"$NAME\""; then
  echo "Certificate \"$NAME\" already exists."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign

echo "Created \"$NAME\" in the login keychain."
