#!/bin/bash
# Live tests on your Mac with VPN Selectivo installed. No password needed
# (uses the limited sudoers rule). In order:
#   1. self-test (PF, tunnel, Mullvad vs. direct IP, IPv6, UDP, kill switch)
#   2. opens the protected apps (etc/apps.conf) and checks that ALL their
#      processes carry the vpnselectivo group (helpers, engines such as node…)
#   3. watches the physical interfaces for packets from those processes (or from
#      system services acting on their behalf) outside the tunnel
# usage: tests/live-tests.sh [watch-seconds]
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
V=/Library/VPNSelectivo/bin/vsctl
SECS="${1:-60}"
GID=$(dscl . -read /Groups/vpnselectivo PrimaryGroupID 2>/dev/null | awk '{print $2}')
[ -n "$GID" ] || { echo "VPN Selectivo is not installed"; exit 1; }

echo "== 1. Self-test"
sudo -n "$V" selftest; st=$?

echo; echo "== 2. Protected apps and their processes"
APPS=$(grep -v "^ *\(#\|$\)" /Library/VPNSelectivo/etc/apps.conf 2>/dev/null)
[ -n "$APPS" ] || { echo "No protected apps (add some in the VPN Selectivo window)"; exit 1; }
seen=""
while IFS='|' read -r id _ path args; do
    id=$(echo "$id" | xargs); path=$(echo "$path" | xargs); args=$(echo "$args" | xargs)
    [ -z "$args" ] || continue                    # once per app, skip variants
    [[ "$seen" == *"|$path|"* ]] && continue; seen="$seen|$path|"
    sudo -n "$V" launch "$id" >/dev/null && echo "  opened: $id"
done <<< "$APPS"
sleep 12
fuera=0
while IFS='|' read -r _ _ path _; do
    path=$(echo "$path" | xargs)
    while read -r pid rgid exe; do
        if [ "$rgid" = "$GID" ]; then echo "  OK    [$pid] ${exe:0:110}"
        else echo "  OUT   [$pid] ${exe:0:110}"; fuera=1; fi
    done < <(ps -axo pid=,rgid=,comm= | grep -F "$path/Contents/" |
             grep -vE 'Updater|Update\.app|Autoupdate|Sparkle|ShipIt|Helper \((Aperitif )?Alerts\)|app_mode_loader|web_app_shortcut_copier' |
             awk '{p=$1; g=$2; $1=$2=""; sub(/^ +/,""); print p, g, $0}')
done <<< "$(echo "$APPS" | awk -F'|' '!seen[$3]++')"
[ $fuera = 0 ] && echo "  All processes of protected apps carry group $GID" || echo "  SOME processes are outside the group"

echo; echo "== 3. Leak watch ($SECS s). Use your protected apps now (browse, stream…)."
sudo -n "$V" leakwatch "$SECS"

echo; echo "== Exit IP"
sudo -n "$V" check-ip
[ $st = 0 ] && [ $fuera = 0 ]
