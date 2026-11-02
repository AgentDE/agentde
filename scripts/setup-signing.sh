#!/bin/zsh
# One-time setup: creates a self-signed code-signing identity, "AgentDE Local Signing", in your login keychain.
#
# Why: an ad-hoc signed app gets a new identity on every rebuild, so macOS forgets the privacy permissions you
# granted (Documents, Downloads, Desktop, ...) after each `make install` and asks again. Signed with a fixed
# identity, every build counts as the same app and your answers stick. build-app.sh uses it automatically.
#
# Usage: scripts/setup-signing.sh            create the identity (asks for confirmation)
#        scripts/setup-signing.sh --remove   delete it again
set -euo pipefail
NAME="AgentDE Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ ${1:-} == --remove ]]; then
  security delete-identity -c "$NAME" "$KEYCHAIN" && echo "Removed \"$NAME\"."
  exit 0
fi

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists. Run make install to sign with it."
  exit 0
fi

echo "This adds a self-signed certificate named \"$NAME\" to your login keychain, usable only for"
echo "signing code (by /usr/bin/codesign). It isn't trusted for anything else. Remove it any time with --remove."
read -q "REPLY?Create it? [y/N] " || { echo; exit 1; }
echo

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS=$(uuidgen)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASS" 2>/dev/null
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\". Now run: make install"
echo "macOS will ask for permissions once more for the newly signed app; after that they stick across rebuilds."
