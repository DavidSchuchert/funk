#!/bin/bash
# Entfernt die erste Version (LaunchAgent + ~/Applications/Funk.app), falls vorhanden.
LABEL="de.schuchert.funk"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ -f "$AGENT" ]; then
  echo "==> Entferne alte Funk-Version (LaunchAgent)"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"
fi
rm -rf "$HOME/Applications/Funk.app"
