#!/bin/bash
# Double-click in Finder to install FileShift.
cd "$(dirname "$0")"
./scripts/install.sh
echo
read -r -p "Press Return to close this window." _
