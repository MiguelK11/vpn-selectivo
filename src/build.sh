#!/bin/bash
# Compila todo VPN Selectivo desde fuentes, en este Mac, sin instalar nada.
#   * wireguard-go 0.0.20250522 + parche NAT de VPNonly (MIT), con sus tests
#   * wg (wireguard-tools 1.0.20260223, GPL-2.0, sin modificar)
#   * vpnrun (C), app de menú, lanzador genérico y generador de iconos (Swift)
# Las descargas se verifican con SHA-256 fijados (los mismos que fija VPNonly
# para WireGuard; el de Go viene de go.dev). Requiere Command Line Tools.
# Resultado: <kit>/build/  (+ build/SHA256SUMS)
set -euo pipefail
umask 022
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH LC_ALL=C

KIT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$KIT/build"
SRC="$KIT/src"

GO_VERSION=1.26.10
GO_SHA256=0b5183492292ada170f9b561a834863808dd02edba599e4ad0e89899330020b3
WGGO_VERSION=0.0.20250522
WGGO_SHA256=c7eeffb13e5eb43b93e54a21d78dd71414771af9e07112da5275690493695c9c
WGT_VERSION=1.0.20260223
WGT_SHA256=af459827b80bfd31b83b08077f4b5843acb7d18ad9a33a2ef532d3090f291fbf

[ "$(uname -m)" = arm64 ] || { echo "Este kit está preparado para Apple Silicon (arm64)."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Faltan las Command Line Tools: ejecuta  xcode-select --install"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/vpnselectivo-build.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

fetch() {   # url archivo sha256
    echo "· descargando $(basename "$2")"
    curl -fsSL --retry 2 -o "$WORK/$2" "$1"
    echo "$3  $WORK/$2" | shasum -a 256 -c --quiet || { echo "SHA-256 incorrecto para $2"; exit 1; }
}
fetch "https://go.dev/dl/go$GO_VERSION.darwin-arm64.tar.gz" go.tgz "$GO_SHA256"
fetch "https://git.zx2c4.com/wireguard-go/snapshot/wireguard-go-$WGGO_VERSION.tar.xz" wgg.tar.xz "$WGGO_SHA256"
fetch "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-$WGT_VERSION.tar.xz" wgt.tar.xz "$WGT_SHA256"

rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/apps"
tar -xzf "$WORK/go.tgz" -C "$WORK"
tar -xf "$WORK/wgg.tar.xz" -C "$WORK"
tar -xf "$WORK/wgt.tar.xz" -C "$WORK"

echo "· wireguard-go + parche NAT"
WGG="$WORK/wireguard-go-$WGGO_VERSION"
patch -d "$WGG" -p1 --forward -s < "$KIT/third_party/wireguard-go-nat.patch"
export GOCACHE="$WORK/gocache" GOMODCACHE="$WORK/gomod" GOTOOLCHAIN=local GOFLAGS=-mod=mod GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org
(cd "$WGG" && CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=13.0 "$WORK/go/bin/go" build -trimpath -buildvcs=false \
    -ldflags='-s -w -buildid=' -o "$OUT/bin/wireguard-go" .)
(cd "$WGG" && "$WORK/go/bin/go" test . >/dev/null) || { echo "tests del parche NAT fallidos"; exit 1; }
"$OUT/bin/wireguard-go" --version | grep -q "v$WGGO_VERSION"

echo "· wg"
make -s -C "$WORK/wireguard-tools-$WGT_VERSION/src" wg >/dev/null
install -m 0755 "$WORK/wireguard-tools-$WGT_VERSION/src/wg" "$OUT/bin/wg"

echo "· vpnrun"
cc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 -o "$OUT/bin/vpnrun" "$SRC/engine/vpnrun.c"

echo "· apps (Swift)"
SWIFTC="xcrun swiftc -O -target arm64-apple-macos13.0"
$SWIFTC -o "$WORK/makeicon" "$SRC/launcher/makeicon.swift"
$SWIFTC -o "$WORK/launcher" "$SRC/launcher/Launcher.swift"
$SWIFTC -o "$WORK/VPNSelectivo" "$SRC/menubar/main.swift" "$SRC/menubar/VPNSelectivo.swift" "$SRC/menubar/ControlWindow.swift"

plist() {   # ruta id nombre ejecutable [VSLaunchApp]
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $2" \
        -c "Add :CFBundleName string $3" -c "Add :CFBundleDisplayName string $3" \
        -c "Add :CFBundleExecutable string $4" -c "Add :CFBundleIconFile string icon" \
        -c "Add :CFBundlePackageType string APPL" -c "Add :CFBundleShortVersionString string 1.0" \
        -c "Add :CFBundleVersion string 1" -c "Add :LSMinimumSystemVersion string 13.0" \
        -c "Add :LSUIElement bool true" -c "Add :NSHighResolutionCapable bool true" "$1" >/dev/null
    [ -z "${5:-}" ] || /usr/libexec/PlistBuddy -c "Add :VSLaunchApp string $5" "$1" >/dev/null
}
bundle() {   # nombre id ejecutable-origen nombre-ejecutable icono-origen color [VSLaunchApp]
    local app="$OUT/apps/$1.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    install -m 0755 "$3" "$app/Contents/MacOS/$4"
    plist "$app/Contents/Info.plist" "$2" "$1" "$4" "${7:-}"
    "$WORK/makeicon" "$5" "$app/Contents/Resources/icon.icns" "$6"
    codesign --force --sign - "$app" >/dev/null 2>&1
}
bundle "VPN Selectivo" local.vpnselectivo.menu "$WORK/VPNSelectivo" VPNSelectivo - 1F8A4C
# App normal: ícono en el Dock y ventana de control (además del escudo).
/usr/libexec/PlistBuddy -c "Set :LSUIElement false" "$OUT/apps/VPN Selectivo.app/Contents/Info.plist"
codesign --force --sign - "$OUT/apps/VPN Selectivo.app" >/dev/null 2>&1
# Los lanzadores del Dock ("<App> VPN.app") los genera vsctl al agregar cada
# app protegida, con estas dos herramientas.
mkdir -p "$OUT/libexec"
install -m 0755 "$WORK/launcher" "$OUT/libexec/launcher"
install -m 0755 "$WORK/makeicon" "$OUT/libexec/makeicon"
for b in launcher makeicon; do codesign --force --sign - "$OUT/libexec/$b" >/dev/null 2>&1; done
for b in wireguard-go wg vpnrun; do codesign --force --sign - "$OUT/bin/$b" >/dev/null 2>&1; done

(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
echo "Compilación terminada en $OUT"
