#!/bin/bash
# Einmalig: Release-Zertifikat erzeugen und als GitHub-Secrets ablegen.
#
#   scripts/create-signing-certificate.sh
#
# Danach signiert der Release-Workflow jede Version mit demselben Schlüssel, und macOS
# behält die Mikrofonfreigabe über Updates hinweg. Läuft auf macOS und in Git Bash.
# Die GitHub CLI (gh) muss angemeldet sein. Pfad notfalls per GH=/pfad/zu/gh übergeben.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Funk Signing"
REPO="DavidSchuchert/funk"
GH="${GH:-gh}"
OUT="build/signing"

if [ -f "$OUT/funk-signing.p12" ]; then
  echo "Es gibt schon ein Zertifikat in $OUT. Abbruch, damit es nicht überschrieben wird."
  echo "Ein neues Zertifikat heißt: Beim nächsten Update fragt macOS wieder nach dem Mikrofon."
  exit 1
fi
command -v "$GH" >/dev/null || { echo "GitHub CLI nicht gefunden. Aufruf mit GH=/pfad/zu/gh"; exit 1; }

echo "==> Erzeuge Zertifikat \"$NAME\""
scripts/make-certificate.sh "$NAME" "$OUT"

echo "==> Lege Secrets im Repo $REPO an"
base64 < "$OUT/funk-signing.p12" | tr -d '\n' | "$GH" secret set FUNK_SIGNING_P12 -R "$REPO"
"$GH" secret set FUNK_SIGNING_PASSWORD -R "$REPO" < "$OUT/password.txt"

if [ "$(uname)" = "Darwin" ]; then
  echo "==> Importiere in den Login-Schlüsselbund (damit auch make install dasselbe Zertifikat nutzt)"
  security import "$OUT/funk-signing.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$(cat "$OUT/password.txt")" -T /usr/bin/codesign >/dev/null
fi

echo
echo "Fertig. Sichere $OUT/funk-signing.p12 und $OUT/password.txt in deinem Passwortmanager"
echo "und lösche den Ordner danach. Er ist per .gitignore vom Repo ausgeschlossen."
