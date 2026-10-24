#!/bin/bash
# VPN Selectivo — update an existing installation. Double-click to run.
# Rebuilds from source and reinstalls the engine, app and sudoers rule; keeps
# your imported Mullvad configuration and your settings. Protected apps can
# stay open (the tunnel survives the service restart).
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
KIT="$(cd "$(dirname "$0")" && pwd)"
echo "VPN Selectivo — update"
"$KIT/src/build.sh" || { read -r -p "The build failed. Press Enter to close." _; exit 1; }
echo "Your administrator password is needed:"
sudo "$KIT/src/update-root.sh" "$KIT" "$(id -un)"
read -r -p "Press Enter to close." _
