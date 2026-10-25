# Acknowledgments

## VPNonly — the engine this project is built on

**VPN Selectivo would not exist without [VPNonly](https://github.com/kanishkdan/vpnonly)
by Kanishk Razdan** ([vpnonly.app](https://vpnonly.app)).

VPNonly is a macOS app that puts only the apps you choose on a WireGuard VPN.
Its author published the privileged engine of the app (`app-engine/`) under the
MIT license, so anyone can read, audit and reuse the part that runs as root.
VPN Selectivo builds on that work:

| From VPNonly | How it is used here |
|---|---|
| **The technique**: launch each protected app under a dedicated Unix group, send that group's traffic into a WireGuard tunnel with PF `route-to`, and block everything else from the group (fail-closed) | The core of VPN Selectivo's design (`src/engine/vsctl`) follows the same idea |
| **`wireguard-go-nat.patch`** — rewrites the inner source address of route-to'd packets so that providers with strict cryptokey routing, such as Mullvad, accept them | Used **unchanged** (`third_party/wireguard-go-nat.patch`), with its tests |
| **`vpnrun.c`** — launches a program as the user but under the VPN group | Adapted (`src/engine/vpnrun.c`); the changes are listed in its header |
| Engine audit notes: DNS is not tunneled, the official Mullvad client may disable PF, pinned WireGuard source hashes | Documented and handled in [docs/TECHNICAL_REPORT.md](docs/TECHNICAL_REPORT.md) |

Source: <https://github.com/kanishkdan/vpnonly>, commit
`50d362783a7fd9dd1b78698c18f196018ffa8c23`. License text:
[third_party/licenses/VPNonly-engine-MIT.txt](third_party/licenses/VPNonly-engine-MIT.txt).

Nothing from VPNonly's commercial app, website, images or videos is used or
redistributed. VPN Selectivo is an independent project and is not affiliated
with or endorsed by VPNonly.

**If you want a polished, supported app with more VPN providers, please use
and support [VPNonly](https://vpnonly.app).**

## Other open-source work

* **[WireGuard](https://www.wireguard.com/)** — `wireguard-go` (MIT, WireGuard
  LLC) and `wireguard-tools` (GPL-2.0, Jason A. Donenfeld), built from their
  official sources. "WireGuard" is a registered trademark of Jason A. Donenfeld.
* **[Mullvad](https://mullvad.net)** — for its public WireGuard relay list API.
  VPN Selectivo is not affiliated with Mullvad VPN AB.
* **[Go](https://go.dev)** — used only to build `wireguard-go`.
