#!/bin/bash
# Erzeugt ein selbst signiertes Code-Signing-Zertifikat als PKCS#12.
# Aufruf: make-certificate.sh <Name> <Zielordner>
# Ergebnis: <Zielordner>/funk-signing.p12 und <Zielordner>/password.txt
# Läuft auf macOS (LibreSSL) und unter Git Bash auf Windows (OpenSSL 3).
set -euo pipefail
export MSYS_NO_PATHCONV=1     # Git Bash: Argumente wie "/CN=..." nicht in Windows-Pfade umbauen

NAME="$1"
OUT="$2"
mkdir -p "$OUT"

if [ -x /usr/bin/openssl ] && [ "$(uname)" = "Darwin" ]; then OPENSSL=/usr/bin/openssl; else OPENSSL=openssl; fi

cat > "$OUT/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

PASS=$($OPENSSL rand -hex 24)
$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -config "$OUT/openssl.cnf" 2>/dev/null

# OpenSSL 3 verschlüsselt PKCS#12 standardmäßig mit AES, das `security import` auf
# macOS nicht in jeder Version liest. Mit 3DES/SHA1 klappt es überall.
EXTRA=()
if $OPENSSL version | grep -q "^OpenSSL 3"; then
  EXTRA=(-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
fi
$OPENSSL pkcs12 -export "${EXTRA[@]}" -inkey "$OUT/key.pem" -in "$OUT/cert.pem" \
  -name "$NAME" -out "$OUT/funk-signing.p12" -passout "pass:$PASS"

printf '%s' "$PASS" > "$OUT/password.txt"
rm -f "$OUT/key.pem" "$OUT/openssl.cnf"
