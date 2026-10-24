#!/bin/bash
# VPN Selectivo — updates an existing installation (root). Used by
# Update.command. Leaves the imported Mullvad configuration, the settings in
# /Library/VPNSelectivo/etc and the official Mullvad client untouched.
# usage: sudo update-root.sh <kit-folder> <user>
set -euo pipefail
umask 022
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH LC_ALL=C
KIT="${1:?usage: update-root.sh <kit> <user>}"
USER_NAME="${2:?usage: update-root.sh <kit> <user>}"
BASE=/Library/VPNSelectivo
APPS="/Applications/VPN Selectivo"

[ "$(id -u)" = 0 ] || { echo "must be run as root"; exit 1; }
[ -d "$BASE/bin" ] || { echo "VPN Selectivo is not installed: use Install.command"; exit 1; }
[[ "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] && USER_UID=$(id -u "$USER_NAME") || { echo "invalid user"; exit 1; }
grep -qx "VS_USER=$USER_NAME" "$BASE/etc/config" || { echo "this installation belongs to another user"; exit 1; }
(cd "$KIT/build" && shasum -a 256 -c --quiet SHA256SUMS) || { echo "build/ does not match SHA256SUMS"; exit 1; }

put() {   # origen destino modo — copia atómica (un script o binario en uso conserva su inodo)
    cp "$1" "$2.new"; chown root:wheel "$2.new"; chmod "$3" "$2.new"; mv -f "$2.new" "$2"
}
put "$KIT/src/engine/vsctl" "$BASE/bin/vsctl" 0755
put "$KIT/src/engine/relays2tsv.js" "$BASE/bin/relays2tsv.js" 0644
put "$KIT/build/bin/wireguard-go" "$BASE/bin/wireguard-go" 0755
put "$KIT/build/bin/wg" "$BASE/bin/wg" 0755
put "$KIT/build/bin/vpnrun" "$BASE/bin/vpnrun" 0700
mkdir -p "$BASE/libexec"; chown root:wheel "$BASE/libexec"; chmod 755 "$BASE/libexec"
put "$KIT/build/libexec/launcher" "$BASE/libexec/launcher" 0755
put "$KIT/build/libexec/makeicon" "$BASE/libexec/makeicon" 0755

# Migración desde la versión con apps fijas: crear apps.conf con las apps que
# ya tenían lanzador (Stremio VPN, Brave VPN, Brave Privado VPN).
if [ ! -f "$BASE/etc/apps.conf" ]; then
    {
        echo "# id | Name | App path | optional arguments | auto (1/0)"
        [ -d "$APPS/Stremio VPN.app" ] && [ -d /Applications/Stremio.app ] &&
            echo "stremio | Stremio | /Applications/Stremio.app |"
        [ -d "$APPS/Brave VPN.app" ] && [ -d "/Applications/Brave Browser.app" ] &&
            echo "brave | Brave | /Applications/Brave Browser.app |"
        [ -d "$APPS/Brave Privado VPN.app" ] && [ -d "/Applications/Brave Browser.app" ] &&
            echo "brave-private | Brave Private | /Applications/Brave Browser.app | --incognito"
    } > "$BASE/etc/apps.conf"
    chown root:wheel "$BASE/etc/apps.conf"; chmod 644 "$BASE/etc/apps.conf"
    echo "apps.conf created from the existing launchers"
fi
[ -f "$KIT/docs/help.html" ] && put "$KIT/docs/help.html" "$BASE/share/help.html" 0644

tmp=$(mktemp /var/run/vpnselectivo-sudoers.XXXXXX)
sed "s/__USER__/$USER_NAME/g" "$KIT/src/engine/sudoers.template" > "$tmp"
if visudo -cf "$tmp" >/dev/null; then
    install -o root -g wheel -m 0440 "$tmp" /etc/sudoers.d/vpnselectivo
    visudo -c >/dev/null || { echo "sudoers invalid after the update"; exit 1; }
else
    echo "NOTE: the new sudoers rule does not validate; keeping the previous one"
fi
rm -f "$tmp"

# Detener la app de menú antes de reemplazarla (si no, macOS la mata por firma
# de código al cambiar su ejecutable en uso) y arrancarla de nuevo al final.
AGENT_PLIST="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')/Library/LaunchAgents/local.vpnselectivo.menu.plist"
launchctl bootout "gui/$USER_UID/local.vpnselectivo.menu" 2>/dev/null || true
mkdir -p "$APPS"
rm -rf "$APPS/.VPN Selectivo.app.new"
cp -R "$KIT/build/apps/VPN Selectivo.app" "$APPS/.VPN Selectivo.app.new"
rm -rf "$APPS/VPN Selectivo.app"; mv "$APPS/.VPN Selectivo.app.new" "$APPS/VPN Selectivo.app"
"$BASE/bin/vsctl" app-sync full   # lanzadores "<App> VPN" desde apps.conf
chown -R root:wheel "$APPS"; chmod -R go-w "$APPS"

launchctl kickstart -k system/local.vpnselectivo.daemon
for _ in $(seq 1 20); do
    ts=$(sed -n 's/.*"ts":\([0-9]*\).*/\1/p' /var/run/vpnselectivo/status.json 2>/dev/null)
    [ -n "$ts" ] && [ $(( $(date +%s) - ts )) -lt 3 ] && break; sleep 0.5
done
"$BASE/bin/vsctl" relays update || echo "NOTE: could not download the server list (it will retry on its own)"
if [ -f "$AGENT_PLIST" ]; then
    # Plantilla actual del LaunchAgent (p. ej. arranque con --background).
    cp "$KIT/src/engine/local.vpnselectivo.menu.plist.template" "$AGENT_PLIST"
    chown "$USER_NAME" "$AGENT_PLIST"; chmod 644 "$AGENT_PLIST"
    launchctl bootstrap "gui/$USER_UID" "$AGENT_PLIST" 2>/dev/null ||
        launchctl kickstart -k "gui/$USER_UID/local.vpnselectivo.menu" 2>/dev/null || true
fi
echo "VPN Selectivo updated."
