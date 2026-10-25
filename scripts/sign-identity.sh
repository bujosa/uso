#!/bin/zsh
set -euo pipefail
name="Uso Local"
if security find-identity -p codesigning | grep -q "$name"; then
  exit 0
fi
dir="${HOME}/Library/Application Support/Uso/signing"
mkdir -p "$dir"
chmod 700 "$dir"
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
  -subj "/CN=${name}" \
  -keyout "$dir/uso.key" -out "$dir/uso.crt" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
openssl pkcs12 -legacy -export -inkey "$dir/uso.key" -in "$dir/uso.crt" -out "$dir/uso.p12" -passout pass:uso >/dev/null 2>&1
security import "$dir/uso.p12" -k "${HOME}/Library/Keychains/login.keychain-db" -P uso -T /usr/bin/codesign -A
rm -f "$dir/uso.p12"
echo "Created signing identity: $name"
