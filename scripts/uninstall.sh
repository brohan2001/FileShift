#!/bin/bash
# Removes the FileShift LaunchAgent and app. Does NOT touch anything in ~/Downloads.
set -euo pipefail
LABEL="io.github.brohan2001.fileshift"
LEGACY_LABELS=("com.fileshift.agent")
APP_DST="$HOME/Applications/FileShift.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/FileShift"
LOGS="$HOME/Library/Logs/FileShift"
DOMAIN="gui/$(id -u)"

echo "==> Stopping FileShift"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for old in "${LEGACY_LABELS[@]}"; do
  launchctl bootout "$DOMAIN/$old" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$old.plist"
done
pkill -x FileShift 2>/dev/null || true

echo "==> Removing LaunchAgent and app"
rm -f "$PLIST"
rm -rf "$APP_DST"

# Keep the journal if an interrupted transaction is pending: it's needed to recover files.
pending=$(ls "$SUPPORT/journal/"*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$pending" != "0" ]; then
  echo "NOTE: $pending unfinished transaction journal(s) remain in $SUPPORT/journal."
  echo "      Kept so you can reinstall and let FileShift recover. Nothing in Downloads was changed."
else
  answer="n"
  if [ -t 0 ]; then read -r -p "Also delete FileShift's logs and settings? [y/N] " answer || true; fi
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf "$SUPPORT" "$LOGS"
    defaults delete io.github.brohan2001.FileShift 2>/dev/null || true
    defaults delete com.fileshift.FileShift 2>/dev/null || true
    echo "==> Logs and settings removed"
  else
    echo "==> Logs kept in $LOGS"
  fi
fi
echo "FileShift has been uninstalled. Your Downloads folder was not modified."
