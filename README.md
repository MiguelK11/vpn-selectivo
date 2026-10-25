# VPN Selectivo

**Reverse split tunneling for Mullvad on macOS: only the apps you choose go through the VPN — everything else keeps your normal connection.**

> 🙏 **Built on the open-source engine of [VPNonly](https://github.com/kanishkdan/vpnonly)** by **Kanishk Razdan**. The core technique — launching apps under a dedicated Unix group, steering that group into a WireGuard tunnel with macOS PF `route-to`, and the `wireguard-go` NAT patch that makes this work with Mullvad — comes from his MIT-licensed work. VPN Selectivo is a small, free, Mullvad-focused companion around that engine. If you want a polished app with support and more providers, please check out and support **[VPNonly](https://vpnonly.app)**. Details in [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).

The official Mullvad app for Mac does the opposite: it puts your **whole** Mac on the VPN and lets you exclude apps. VPN Selectivo is for when you want, say, **only your torrent-based streaming app and one browser** on Mullvad, while your work apps, video calls and everything else stay on your regular connection.

* **Only the chosen apps** use Mullvad — including every process they spawn (browser helpers, torrent engines such as Stremio's `node`, …).
* **Fail-closed**: if the tunnel drops, protected apps lose connectivity instead of falling back to your normal connection. IPv6 and ICMP are blocked for them.
* **Control window in the Dock**: VPN on/off switch, live status (server, real exit IP, which apps are being routed right now), location picker and an app list to check/uncheck. There is also a shield icon in the menu bar.
* **Pick a country, city or server**, like in the official app (uses Mullvad's public relay list).
* **Auto-VPN**, globally and per app (⚡): opening certain apps turns the VPN on, closing them turns it off.
* **Check/uncheck apps instantly**, no password needed; each protected app also gets an "‹App› VPN" Dock launcher. If the app is already running, you are offered a clean restart so it moves into (or out of) the tunnel.
* **Apps opened "the wrong way"** (original Dock icon, Spotlight, a link) are closed instantly and reopened protected.
* **English and Spanish** interface, following your Mac's language.
* Free, small and auditable; compiled on your Mac from verified upstream sources — no third-party binaries.

---

## Requirements

* A Mac with **Apple Silicon**, macOS 13 or later (tested on macOS 26.5).
* An active **Mullvad** account (uses 1 of your 5 devices).
* Xcode **Command Line Tools**: `xcode-select --install`.


## Installation

1. **Get this repository** (green *Code › Download ZIP* button, then unzip), or:
   ```bash
   git clone https://github.com/MiguelK11/vpn-selectivo.git
   ```
2. **Generate a Mullvad WireGuard configuration**: go to <https://mullvad.net/en/account/wireguard-config>, click *Generate key*, pick any country and download the `.conf` (or the `.zip`). The private key **never leaves your Mac**, and one configuration is enough to use any server.
3. **Quit the apps you want to protect** (Cmd+Q).
4. Double-click **`Install.command`**. It builds everything (about 2 minutes), asks for your administrator password once, asks which apps to protect and asks you to drag in the Mullvad configuration.

   > If macOS refuses to open the file, right-click it › *Open*, or run `xattr -dr com.apple.quarantine <repository-folder>` in Terminal.
5. **Disconnect the official Mullvad app** if you use it (no need to uninstall it): while it is connected, your *whole* Mac goes through the VPN.
6. Drag the launchers from `/Applications/VPN Selectivo/` to your Dock and remove the original icons of the protected apps.

## Daily use

Open **VPN Selectivo** from the Dock (or the menu-bar shield › *Open Control Panel…*):

* **VPN switch** (top right): turn it on and the tunnel stays up until you turn it off. Turn it off and **checked** apps lose Internet access (they never use your normal connection); unchecked apps are unaffected.
* **Live status**: connected/disconnected, country, city, server, **real exit IP**, and which apps are going through the tunnel right now.
* **Location**: country › city › server (or automatic). Changing it reconnects the tunnel by itself; during the switch, checked apps are blocked, not leaking.
* **Auto-VPN**: see below.
* **Apps**: the list of `/Applications`, with search and a *Checked only* filter. Each row shows whether the app is running and which way its traffic goes.
* Buttons: *Check IP*, *Self-Test* (includes deliberately dropping the tunnel), *Watch for Leaks*, *Import Configuration…* and *Log*.

You can also open each app with its **"‹App› VPN"** launcher in `/Applications/VPN Selectivo/`. If you open a checked app with its original icon, it is closed instantly and reopened protected.

### Auto-VPN

* A **global switch** "Auto-VPN" and a **⚡ checkbox per app**.
* An app with ⚡: opening it turns the VPN on; 2 minutes after the last ⚡ app is closed, it turns off. It also turns the VPN back on if you had switched it off manually.
* A checked app **without** ⚡ (or with Auto-VPN off) only has Internet access while the VPN is already on (via the switch or another ⚡ app). Otherwise it stays offline — it never uses your normal connection.

## Adding or removing apps

### From the control window (easiest)

In the **Apps** list, turn an app's switch on to route it through Mullvad, or off to give it your normal connection. It is instant and needs no password.

* **If the app is running** when you check it: for safety its route cannot change while it runs (that is decided at launch). Choose *Restart Now* (it quits cleanly and reopens protected) or *When I Quit It* (it keeps your normal connection until you quit it; it is left alone meanwhile). Unchecking a running app works the same way in reverse.
* Apps that cannot be protected (Apple apps, other VPNs, Automator launchers) are dimmed and show the reason.
* The menu-bar shield also has *Protected Apps › Add / Remove*.

### From Terminal

```bash
# list protected apps
cat /Library/VPNSelectivo/etc/apps.conf

# add (lowercase id, display name, app path) — no password needed
sudo /Library/VPNSelectivo/bin/vsctl app-add firefox "Firefox" "/Applications/Firefox.app"

# a variant with arguments: Brave's private window as a separate launcher
sudo /Library/VPNSelectivo/bin/vsctl app-add brave-private "Brave Private" "/Applications/Brave Browser.app" --incognito

# Auto-VPN for one app (1/0) and globally (on/off)
sudo /Library/VPNSelectivo/bin/vsctl app-auto firefox 0
sudo /Library/VPNSelectivo/bin/vsctl set-auto off

# remove
sudo /Library/VPNSelectivo/bin/vsctl app-remove firefox
```

`apps.conf` has one line per app: `id | Name | /Applications/App.app | optional arguments | auto (1/0)`. Several lines may point to the same app with different arguments: they share the protection and each gets its own launcher. Only apps in `/Applications` or `~/Applications` are accepted.

### Which apps work well?

Protection follows the app and **every process it creates**. It works very well with apps that make their own network connections:

| Works well | Partial coverage | Does not work |
|---|---|---|
| Chromium browsers (Brave, Chrome, Edge, Vivaldi, Opera), Firefox | Apps that use `WKWebView`, `AVPlayer` or Apple background downloads: those parts are handled by system services and bypass the VPN (e.g. Stremio 2.x — its torrent engine *is* protected) | Safari, Mail, App Store and Apple apps that delegate networking to the system |
| Electron apps (Discord, Spotify, Slack…) | Apps with their own updater: the updater bypasses the VPN | Apps that need to see devices on your local network (Chromecast, AirPlay, printers), unless you set `ALLOW_LAN=1` |
| Torrent clients (qBittorrent, Transmission), Stremio (torrent engine) | | |

Always check a new app with *Watch for Leaks* while using it.

## How it works

```
 Protected apps ──(Unix group "vpnselectivo", inherited by child processes)──┐
                                                                            │ PF anchor com.apple/vpnselectivo
 Rest of the Mac ──(normal group)──► normal route                           │ route-to ──► utunN (wireguard-go)
                                                                            │                  └─► Mullvad
                               anything else from the group ──► BLOCKED (IPv6, ICMP, tunnel down)
```

1. **`vpnrun`** launches the app as you, but with the `vpnselectivo` group; its child processes inherit it.
2. The macOS firewall (**PF**) uses `route-to` to send all IPv4 TCP/UDP from that group into the tunnel, and **blocks** everything else from it. The rest of the Mac is untouched: the default route is never changed.
3. **`wireguard-go`** (with VPNonly's NAT patch, required for Mullvad) runs the tunnel, without any routes of its own.
4. A **root service** (LaunchDaemon) checks every second. If something disables PF or alters the rules, it **freezes** protected apps (SIGSTOP, nothing is closed), repairs the rules and resumes them. If the tunnel drops, it blocks and reconnects. If a protected app was opened outside the VPN, it closes it.
5. The **app** (control window + menu-bar shield) shows the status, changes the location, checks/unchecks apps and reopens apps that were opened outside the VPN — protected, and with `--restore-last-session` for Chromium browsers.

Details, the audit of VPNonly's engine and all test results are in [docs/TECHNICAL_REPORT.md](docs/TECHNICAL_REPORT.md).

## Security and leaks

| Vector | Handling |
|---|---|
| IPv4 TCP/UDP of protected apps and their children | Through the tunnel |
| IPv6, ICMP, other protocols | Blocked for protected apps |
| Tunnel down / unresponsive server | No connectivity, never the normal route; automatic reconnection |
| PF disabled by another program | Apps frozen within ≤1 s, PF repaired, apps resumed |
| App opened outside the VPN | Closed instantly and reopened protected |
| DNS | Apps that resolve names through the system (`mDNSResponder`) reveal **hostnames** to your resolver (not the traffic itself). In browsers, enable secure DNS (e.g. `https://dns.mullvad.net/dns-query`) |
| Local network | Blocked by default for protected apps (`ALLOW_LAN=1` in `/Library/VPNSelectivo/etc/config` allows the local subnet, with the router always blocked) |

**Permissions**: checking/unchecking apps, changing location and switching the VPN on/off need no password — just like the official Mullvad app's exclusion list. As a consequence, any program running as your user could change that list. `vsctl` only accepts apps in `/Applications` or `~/Applications`, never gives them extra privileges (they run as you) and logs every change. Importing the Mullvad key does require your password.

**Optional extra layer for Brave**: the installer offers a configuration profile that forces Brave to use Mullvad's internal SOCKS proxy (`10.64.0.1:1080`). Even if Brave were opened outside the VPN it would have no connection, and its DNS would be resolved by Mullvad.

### Honest limitations

1. System services acting **on behalf of** an app (WebKit, `nsurlsessiond`, `mDNSResponder`…) don't inherit the group and bypass the VPN. No per-process method can avoid this — official split tunneling included.
2. If another program disables PF, there is a window of ≤1 s before apps are frozen.
3. An app opened outside the VPN lives for a few milliseconds (up to 1 s if the app is not running) before being closed. In testing it never managed to send a packet, but that is not an absolute guarantee.
4. Local multicast (mDNS) from some apps may reach your local network: PF cannot attribute it when the port is shared with the system. It never leaves your network.
5. IPv4 only inside the tunnel. No quantum resistance or DAITA (those are specific to the official client).
6. While the official Mullvad app is connected, your whole Mac goes through the VPN.

## Testing that it works

* Control window › *Self-Test*: checks PF, the tunnel, Mullvad exit IP vs. direct IP, IPv6 and UDP, and deliberately drops the tunnel to confirm nothing leaks.
* `tests/live-tests.sh`: opens your protected apps, checks that **all** their processes carry the group, and watches the physical interfaces (macOS PKTAP, by process and by "effective process").
* `tests/unit.sh`: 75 tests of the logic, no root needed.

## Updating and uninstalling

* **`Update.command`**: rebuilds and reinstalls, keeping your configuration and apps. Protected apps can stay open.
* **`Uninstall.command`**: stops the tunnel and removes the PF rules, the service, the sudoers rule, the apps and the group. It does not touch the official Mullvad app. Afterwards you can revoke the key at mullvad.net › Devices.

## What gets installed

| Path | What it is |
|---|---|
| `/Library/VPNSelectivo/` | Engine (root): `vsctl`, `vpnrun`, `wireguard-go`, `wg`; configuration in `etc/` (the Mullvad key, in `etc/servers/`, is readable by root only) |
| `/Library/LaunchDaemons/local.vpnselectivo.daemon.plist` | Watchdog service |
| `/etc/sudoers.d/vpnselectivo` | Allows only specific `vsctl` commands without a password (open apps, on/off, location, check apps, Auto-VPN, diagnostics); importing the Mullvad configuration (private key) requires a password |
| `/Applications/VPN Selectivo/` | Control app and "‹App› VPN" launchers |
| `~/Library/LaunchAgents/local.vpnselectivo.menu.plist` | Starts the app (Dock + menu bar) at login |
| Group `vpnselectivo` (GID 7300–7899) | Marks protected traffic |
| `/Library/Logs/VPNSelectivo.log` | Log |

## Credits and licenses

* Own code: **MIT** (see [LICENSE](LICENSE)).
* **[VPNonly](https://github.com/kanishkdan/vpnonly)** © 2026 Kanishk Razdan (MIT): the per-app routing design (dedicated group + PF `route-to` + fail-closed block), the `wireguard-go` NAT patch (used unchanged) and the basis of `vpnrun.c`. See [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md). If you want a polished app with support and more providers, **[VPNonly](https://vpnonly.app)** is its author's commercial product.
* **wireguard-go** (MIT, WireGuard LLC) and **wireguard-tools `wg`** (GPL-2.0) are built from their official sources — no prebuilt binaries. See [third_party/NOTICES.md](third_party/NOTICES.md).
* "WireGuard" is a registered trademark of Jason A. Donenfeld. "Mullvad" is a trademark of Mullvad VPN AB. This project is not affiliated with either.

## Repository layout

```
Install.command  Update.command  Uninstall.command
src/engine/vsctl            root controller + watchdog service (bash)
src/engine/vpnrun.c         group launcher (C, derived from VPNonly)
src/engine/relays2tsv.js    Mullvad public relay list → TSV
src/engine/*.plist, sudoers.template
src/menubar/                control window (SwiftUI), menu-bar shield and watchdog
src/launcher/               generic "‹App› VPN" launcher and icon generator
src/build.sh                reproducible build from verified sources
src/update-root.sh          update (used by Update.command)
src/brave-profile.sh        optional Brave profile
third_party/                NAT patch and licenses
tests/                      unit.sh (no root) and live-tests.sh
docs/                       technical report and in-app help
```
