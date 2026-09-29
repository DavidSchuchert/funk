#!/bin/bash
# Legt einmalig ein selbst signiertes Code-Signing-Zertifikat im Login-Schlüsselbund an.
#
# Warum: macOS merkt sich die Mikrofonfreigabe an der "Designated Requirement" der App.
# Bei ad-hoc-Signatur ändert die sich mit jedem Build, und macOS fragt nach jedem Update neu.
# Mit festem Zertifikat bleibt die Freigabe über Updates hinweg erhalten.
set -euo pipefail

NAME="$1"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  exit 0
fi

echo "==> Lege lokales Signaturzertifikat \"$NAME\" an (nur beim ersten Mal)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CNF
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

# Bewusst /usr/bin/openssl (LibreSSL von Apple): Ein OpenSSL 3 aus Homebrew erzeugt
# PKCS#12-Dateien, die `security import` ohne -legacy nicht lesen kann.
OPENSSL=/usr/bin/openssl
PASS="funk-$$"
$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
$OPENSSL pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"

# -T erlaubt codesign den Schlüsselzugriff ohne Nachfrage.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "    Fertig. Falls macOS beim Signieren nach dem Schlüsselbund fragt: \"Immer erlauben\"."
