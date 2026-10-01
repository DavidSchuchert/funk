#!/bin/bash
# Stellt sicher, dass das Code-Signing-Zertifikat existiert.
#
# Warum: macOS merkt sich die Mikrofonfreigabe an der "Designated Requirement" der App.
# Bei ad-hoc-Signatur ändert die sich mit jedem Build. Mit festem Zertifikat bleibt die
# Freigabe über Updates hinweg erhalten.
#
# Gesucht wird in allen Schlüsselbunden der Suchliste. In CI ist das importierte
# Release-Zertifikat dabei, auf einem Mac evtl. eins aus create-signing-certificate.sh.
# Nur wenn keins da ist, wird lokal eins angelegt (reicht für make install).
set -euo pipefail

NAME="$1"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  exit 0
fi
if [ -n "${CI:-}" ]; then
  echo "Fehler: Zertifikat \"$NAME\" nicht im Schlüsselbund. Secret FUNK_SIGNING_P12 gesetzt?" >&2
  exit 1
fi

echo "==> Kein Zertifikat \"$NAME\" gefunden, lege ein lokales an (nur für make install)"
echo "    Hinweis: Mit dem Release-Zertifikat (scripts/create-signing-certificate.sh) wären"
echo "    lokale Builds und DMG-Versionen für macOS dieselbe App."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"$(dirname "$0")/make-certificate.sh" "$NAME" "$TMP"
security import "$TMP/funk-signing.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$(cat "$TMP/password.txt")" -T /usr/bin/codesign >/dev/null
echo "    Fertig. Falls macOS beim Signieren nach dem Schlüsselbund fragt: \"Immer erlauben\"."
