#!/bin/bash
# VPN Selectivo — installer. Double-click to run it in Terminal.
# Asks for your administrator password ONCE (sudo). It does not change the
# official Mullvad app's settings, your other apps, or their connection.
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH LC_ALL=C
KIT="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(id -un)"
USER_HOME="$HOME"
BASE=/Library/VPNSelectivo
APPS="/Applications/VPN Selectivo"
DAEMON_PLIST=/Library/LaunchDaemons/local.vpnselectivo.daemon.plist
AGENT_PLIST="$USER_HOME/Library/LaunchAgents/local.vpnselectivo.menu.plist"
SUDOERS=/etc/sudoers.d/vpnselectivo

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR: %s\033[0m\n' "$*"; read -r -p "Press Enter to close." _; exit 1; }
ask()  { local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[yYsS] ]]; }

clear
cat <<EOF
VPN Selectivo — only the apps you choose go through Mullvad; the rest of your Mac doesn't
========================================================================================
This will install:
  • /Library/VPNSelectivo            the engine (owned by root, read-only for you)
  • /Applications/VPN Selectivo      the control app and one "<App> VPN" launcher
                                     for each app you protect
  • a system service (LaunchDaemon) and a narrowly scoped sudoers rule
  • the Unix group "vpnselectivo" (it marks protected traffic)
Left untouched: the official Mullvad app, your other apps and their connection.
EOF

[ "$(id -u)" != 0 ] || fail "Run this as your normal user, not as root."
[ "$(uname -m)" = arm64 ] || fail "This kit is built for Apple Silicon Macs."

# 1. Build (unless a verified build is already present)
if [ ! -f "$KIT/build/SHA256SUMS" ]; then
    say "1/7  Building from source (downloads verified Go and WireGuard sources; ~2 min)…"
    "$KIT/src/build.sh" || fail "The build failed."
else
    say "1/7  Verifying the included build…"
    (cd "$KIT/build" && shasum -a 256 -c --quiet SHA256SUMS) || fail "build/ does not match SHA256SUMS; delete build/ and try again."
fi

# 2. Apps to protect (first install only; afterwards use the control window).
CHOSEN=()   # "id|Name|path|args"
if [ ! -f "$BASE/etc/apps.conf" ]; then
    say "2/7  Which apps must ALWAYS use Mullvad?"
    echo "(You can add or remove apps at any time from the VPN Selectivo window.)"
    for sug in "stremio|Stremio|/Applications/Stremio.app" "brave|Brave|/Applications/Brave Browser.app" \
               "firefox|Firefox|/Applications/Firefox.app" "qbittorrent|qBittorrent|/Applications/qbittorrent.app" \
               "transmission|Transmission|/Applications/Transmission.app"; do
        IFS='|' read -r sid sname spath <<< "$sug"
        [ -d "$spath" ] || continue
        if ask "  Protect $sname?"; then
            CHOSEN+=("$sid|$sname|$spath|")
            [ "$sid" = brave ] && ask "    Also add a \"Brave Private\" launcher (private window)?" &&
                CHOSEN+=("brave-private|Brave Private|$spath|--incognito")
        fi
    done
    while ask "  Pick another app from a dialog?"; do
        p=$(osascript -e 'POSIX path of (choose application with prompt "App that must always use the VPN" as alias)' 2>/dev/null) || continue
        p="${p%/}"
        n=$(basename "$p" .app | tr -d "\"'\\\\\$\`|<>;&/" | cut -c1-40)
        id=$(printf '%s' "$n" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//' | cut -c1-30)
        [ -n "$id" ] || id=app
        CHOSEN+=("$id|$n|$p|"); echo "    + $n ($p)"
    done
fi

# Apps to protect must be closed (otherwise the service would close them).
say "Checking that the apps to protect are closed…"
CLOSE_RE=""
for c in ${CHOSEN[@]+"${CHOSEN[@]}"}; do IFS='|' read -r _ _ cp _ <<< "$c"; CLOSE_RE="$CLOSE_RE|^$cp/Contents/MacOS/"; done
[ -f "$BASE/etc/apps.conf" ] && while IFS='|' read -r _ _ cp _; do
    cp=$(echo "$cp" | sed 's/^ *//; s/ *$//'); [ -n "$cp" ] && CLOSE_RE="$CLOSE_RE|^$cp/Contents/MacOS/"
done < <(grep -v '^#' "$BASE/etc/apps.conf")
CLOSE_RE="${CLOSE_RE#|}"
while [ -n "$CLOSE_RE" ] && pgrep -f "$CLOSE_RE" >/dev/null; do
    echo "Some apps to protect are open. Quit them with Cmd+Q (browsers restore their tabs"
    echo "if \"Continue where you left off\" is enabled)."
    read -r -p "Press Enter once they are closed (or Ctrl+C to cancel)… " _
done

# 3. Official Mullvad app: information only.
if [ -x /usr/local/bin/mullvad ]; then
    st=$(/usr/local/bin/mullvad status 2>/dev/null | head -n1)
    case "$st" in
        Connected*|Connecting*)
            say "NOTE: the official Mullvad app is connected ($st)."
            echo "While it is, your WHOLE Mac goes through Mullvad. VPN Selectivo works without it:"
            echo "disconnect it whenever you want this mode. Its settings are not changed." ;;
    esac
fi

say "3/7  Your administrator password is needed:"
sudo -v || fail "No administrator rights."
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT

# 4. Dedicated group (private GID 7300–7899)
say "4/7  Group and system files…"
GID=$(dscl . -read /Groups/vpnselectivo PrimaryGroupID 2>/dev/null | awk '{print $2}')
if [ -z "$GID" ]; then
    for g in $(seq 7350 7899) $(seq 7300 7349); do
        dscl . -list /Groups PrimaryGroupID | awk -v g="$g" '$2 == g {f=1} END {exit f}' && { GID=$g; break; }
    done
    sudo dseditgroup -o create -i "$GID" -r "VPN Selectivo" vpnselectivo || fail "could not create the group"
fi
[ "$GID" -ge 7300 ] && [ "$GID" -le 7899 ] || fail "group vpnselectivo exists with an out-of-range GID ($GID)"
echo "Group vpnselectivo = $GID"

# 5. Engine
sudo launchctl bootout system "$DAEMON_PLIST" 2>/dev/null
sudo mkdir -p "$BASE/bin" "$BASE/etc/servers" "$BASE/share" "$BASE/licenses"
sudo install -o root -g wheel -m 0755 "$KIT/src/engine/vsctl" "$BASE/bin/vsctl"
sudo install -o root -g wheel -m 0755 "$KIT/build/bin/wireguard-go" "$BASE/bin/wireguard-go"
sudo install -o root -g wheel -m 0755 "$KIT/build/bin/wg" "$BASE/bin/wg"
sudo install -o root -g wheel -m 0700 "$KIT/build/bin/vpnrun" "$BASE/bin/vpnrun"
sudo install -o root -g wheel -m 0644 "$KIT/src/engine/relays2tsv.js" "$BASE/bin/relays2tsv.js"
sudo mkdir -p "$BASE/libexec"
sudo install -o root -g wheel -m 0755 "$KIT/build/libexec/launcher" "$BASE/libexec/launcher"
sudo install -o root -g wheel -m 0755 "$KIT/build/libexec/makeicon" "$BASE/libexec/makeicon"
sudo install -o root -g wheel -m 0644 "$KIT/third_party/licenses/"* "$BASE/licenses/"
sudo install -o root -g wheel -m 0644 "$KIT/third_party/wireguard-go-nat.patch" "$BASE/licenses/"
[ -f "$KIT/docs/help.html" ] && sudo install -o root -g wheel -m 0644 "$KIT/docs/help.html" "$BASE/share/help.html"
if [ ! -f "$BASE/etc/config" ]; then
    printf 'VS_USER=%s\nALLOW_LAN=0\nENFORCE=1\nIDLE_DOWN_SECONDS=120\nMTU=1380\n' "$USER_NAME" > "$KIT/.config.tmp"
    sudo install -o root -g wheel -m 0644 "$KIT/.config.tmp" "$BASE/etc/config"; rm -f "$KIT/.config.tmp"
fi
sudo chown -R root:wheel "$BASE"; sudo chmod 755 "$BASE" "$BASE/bin" "$BASE/libexec" "$BASE/etc" "$BASE/share" "$BASE/licenses"
sudo chmod 700 "$BASE/etc/servers"

# sudoers: validated with visudo before installing
sed "s/__USER__/$USER_NAME/g" "$KIT/src/engine/sudoers.template" > "$KIT/.sudoers.tmp"
visudo -cf "$KIT/.sudoers.tmp" >/dev/null || { rm -f "$KIT/.sudoers.tmp"; fail "the sudoers rule does not validate"; }
sudo install -o root -g wheel -m 0440 "$KIT/.sudoers.tmp" "$SUDOERS"; rm -f "$KIT/.sudoers.tmp"
sudo visudo -c >/dev/null || { sudo rm -f "$SUDOERS"; fail "sudoers became invalid; rule removed"; }

# 6. App
sudo mkdir -p "$APPS"; sudo rm -rf "$APPS/VPN Selectivo.app"
sudo cp -R "$KIT/build/apps/VPN Selectivo.app" "$APPS/"
sudo chown -R root:wheel "$APPS"; sudo chmod -R go-w "$APPS"

# 7. Services
say "5/7  Starting the service…"
sudo install -o root -g wheel -m 0644 "$KIT/src/engine/local.vpnselectivo.daemon.plist" "$DAEMON_PLIST"
sudo launchctl bootstrap system "$DAEMON_PLIST" || fail "could not start the LaunchDaemon"
for _ in $(seq 1 30); do [ -f /var/run/vpnselectivo/status.json ] && break; sleep 0.5; done
sudo -n "$BASE/bin/vsctl" status >/dev/null || fail "the service does not respond (see /Library/Logs/VPNSelectivo.log)"
mkdir -p "$USER_HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null
cp "$KIT/src/engine/local.vpnselectivo.menu.plist.template" "$AGENT_PLIST"
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" || echo "NOTE: open /Applications/VPN Selectivo/VPN Selectivo.app manually"

# Protected apps and their Dock launchers
for c in ${CHOSEN[@]+"${CHOSEN[@]}"}; do
    IFS='|' read -r cid cname cpath cargs <<< "$c"
    # shellcheck disable=SC2086  # optional, simple arguments
    sudo "$BASE/bin/vsctl" app-add "$cid" "$cname" "$cpath" $cargs || echo "NOTE: could not protect $cname"
done
sudo "$BASE/bin/vsctl" app-sync >/dev/null
echo "Protected apps:"; sudo "$BASE/bin/vsctl" apps | sed 's/^/  /'
sudo "$BASE/bin/vsctl" relays update || echo "NOTE: the server list will be downloaded later"

# Mullvad configuration
say "6/7  Mullvad WireGuard configuration"
if sudo -n "$BASE/bin/vsctl" servers | grep -q .; then
    echo "Servers already imported:"; sudo -n "$BASE/bin/vsctl" servers
fi
cat <<'EOF'
If you don't have one yet: go to https://mullvad.net/en/account/wireguard-config
  → "Generate key" → pick any country → download the .zip or a .conf file.
  (It uses one of your account's 5 devices. The key NEVER leaves this Mac.)
EOF
read -r -p "Drag the .zip/.conf here and press Enter (or just Enter to do it later from the app): " CONF
CONF="${CONF%"${CONF##*[![:space:]]}"}"; CONF="${CONF#\'}"; CONF="${CONF%\'}"; CONF="${CONF//\\ / }"
if [ -n "$CONF" ]; then
    sudo "$BASE/bin/vsctl" import "$CONF" || echo "Import failed; you can do it later from the app."
fi

# Optional Brave policy (only if Brave is protected)
if grep -q '/Applications/Brave Browser.app' "$BASE/etc/apps.conf" 2>/dev/null; then
say "7/7  Optional extra layer for Brave"
cat <<'EOF'
I can generate a configuration profile that forces Brave to use Mullvad's
internal proxy (socks5://10.64.0.1:1080). Effect: even if Brave were opened
outside the VPN it would have NO connection, and its DNS lookups are resolved
by Mullvad. Brave will show "Managed by your organization". It is installed in
System Settings › General › Device Management and removed from there.
EOF
if ask "Generate and open the Brave profile?"; then
    "$KIT/src/brave-profile.sh" "$KIT/Brave-Mullvad-only.mobileconfig" &&
        open "$KIT/Brave-Mullvad-only.mobileconfig" &&
        echo "Now go to System Settings › General › Device Management and install it."
fi
fi

say "Installation finished."
cat <<EOF
• Open "VPN Selectivo" (Dock) for the control window: VPN switch, location,
  Auto-VPN and the apps to protect (check/uncheck, no password needed).
• You can also use the "<App> VPN" launchers in /Applications/VPN Selectivo or the
  shield in the menu bar. Remove the original icons of protected apps from the
  Dock (if you open them that way, they are closed and reopened protected).
• Test it: control window › "Autodiagnóstico" (self-test button).
• Disconnect the official Mullvad app so the rest of your Mac stays off the VPN.
• Log: /Library/Logs/VPNSelectivo.log   Uninstall: Uninstall.command
EOF
read -r -p "Press Enter to close." _
