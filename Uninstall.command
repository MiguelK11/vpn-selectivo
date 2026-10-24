#!/bin/bash
# VPN Selectivo — uninstaller. Leaves the Mac as it was before installing:
# stops the tunnel, empties the PF anchor and releases the PF reference, and
# removes the service, the sudoers rule, the apps, the engine and the group.
# It does not touch the official Mullvad app or your apps' settings.
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH LC_ALL=C
BASE=/Library/VPNSelectivo
AGENT_PLIST="$HOME/Library/LaunchAgents/local.vpnselectivo.menu.plist"
DAEMON_PLIST=/Library/LaunchDaemons/local.vpnselectivo.daemon.plist

echo "VPN Selectivo — uninstall"
GID=$(dscl . -read /Groups/vpnselectivo PrimaryGroupID 2>/dev/null | awk '{print $2}')
# Without the PF anchor, a process that still carries the group would go out
# WITHOUT the VPN: protected apps must be closed first.
while [ -n "$GID" ] && pgrep -G "$GID" >/dev/null 2>&1; do
    echo "Some protected apps are still open. Quit them with Cmd+Q."
    read -r -p "Press Enter once they are closed (Ctrl+C to cancel)… " _
done

sudo -v || { echo "Your administrator password is needed."; exit 1; }
launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null; rm -f "$AGENT_PLIST"
pkill -f '/VPN Selectivo.app/Contents/MacOS/VPNSelectivo' 2>/dev/null
sudo launchctl bootout system "$DAEMON_PLIST" 2>/dev/null
[ -x "$BASE/bin/vsctl" ] && sudo "$BASE/bin/vsctl" _uninstall
sudo rm -f "$DAEMON_PLIST" /etc/sudoers.d/vpnselectivo
sudo rm -rf "$BASE" "/Applications/VPN Selectivo" /var/run/vpnselectivo
[ -n "$GID" ] && sudo dseditgroup -o delete vpnselectivo 2>/dev/null
if profiles list 2>/dev/null | grep -q local.vpnselectivo.brave ||
   sudo profiles list 2>/dev/null | grep -q local.vpnselectivo.brave; then
    echo "The \"Brave: Mullvad only\" profile is still installed: remove it in"
    echo "System Settings › General › Device Management."
fi
read -r -p "Also delete the log /Library/Logs/VPNSelectivo*.log? [y/N] " a
[[ "$a" =~ ^[yYsS] ]] && sudo rm -f /Library/Logs/VPNSelectivo*.log*
echo
echo "Uninstalled. Note: the WireGuard key you generated is still registered as a device"
echo "on your Mullvad account; you can revoke it at mullvad.net › Devices."
read -r -p "Press Enter to close." _
