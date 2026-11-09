#!/bin/bash
# Double-click in Finder to uninstall FileShift.
cd "$(dirname "$0")"
./scripts/uninstall.sh
echo
read -r -p "Press Return to close this window." _
