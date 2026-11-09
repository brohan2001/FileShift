#!/bin/bash
# Installs FileShift for the current user: builds (or uses a prebuilt app), copies it to
# ~/Applications, installs and starts the LaunchAgent. Never touches the contents of ~/Downloads.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="io.github.brohan2001.fileshift"
LEGACY_LABELS=("com.fileshift.agent")
APP_DST="$HOME/Applications/FileShift.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ -f "$ROOT/Package.swift" ]; then
  if ! command -v swift >/dev/null 2>&1; then
    echo "Swift is not installed. Install the Xcode Command Line Tools with:  xcode-select --install" >&2
    exit 1
  fi
  "$ROOT/scripts/build-app.sh"
elif [ -d "$ROOT/build/FileShift.app" ]; then
  echo "==> Using prebuilt app"
  # A downloaded release is quarantined by macOS; clear it so Gatekeeper doesn't block launch.
  xattr -dr com.apple.quarantine "$ROOT/build/FileShift.app" 2>/dev/null || true
else
  echo "Neither source code nor a prebuilt FileShift.app was found next to this script." >&2
  exit 1
fi

if command -v brew >/dev/null 2>&1 && brew list --formula fileshift >/dev/null 2>&1; then
  echo "NOTE: FileShift is also installed via Homebrew. Only one copy runs at a time;"
  echo "      consider 'brew services stop fileshift && brew uninstall fileshift'."
fi

echo "==> Stopping any running copy"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for old in "${LEGACY_LABELS[@]}"; do
  launchctl bootout "$DOMAIN/$old" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$old.plist"
done
pkill -x FileShift 2>/dev/null || true

echo "==> Installing to $APP_DST"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/FileShift"
rm -rf "$APP_DST"
cp -R "$ROOT/build/FileShift.app" "$APP_DST"

echo "==> Writing LaunchAgent $PLIST"
sed -e "s#__APP__#$APP_DST#g" -e "s#__HOME__#$HOME#g" \
  "$ROOT/Resources/$LABEL.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

echo "==> Starting"
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true

sleep 1
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo
  echo "FileShift is installed and running (look for the ⟳ icon in the menu bar)."
  echo "If macOS asks whether FileShift may access your Downloads folder, click Allow."
  echo "Log: ~/Library/Logs/FileShift/fileshift.log"
else
  echo "LaunchAgent did not load; see: launchctl print $DOMAIN/$LABEL" >&2
  exit 1
fi
