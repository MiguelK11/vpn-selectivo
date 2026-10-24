# Technical report — VPN Selectivo

Design, audit and test results. Reference setup used to develop and test it:
**Stremio 2.1.0** (with its `node` torrent engine), **Brave** and a launcher for
Brave's private window, on **macOS 26.5 / Apple Silicon**, with **Mullvad
2026.5**. Protected apps are configurable (`apps.conf`); see the
[README](../README.md).

> IP addresses, locations and machine details from the tests have been omitted
> or generalized.

## 1. Decision: build a small app on VPNonly's open engine

| | Mullvad's own split tunneling | Full VPNonly app | **VPN Selectivo (chosen)** |
|---|---|---|---|
| Model | Whole Mac on the VPN, **exclude** apps | Only chosen apps on the VPN | Only chosen apps on the VPN |
| New apps / other browsers | Each one must be excluded (helpers too) | Off the VPN by default | Off the VPN by default |
| System processes | Go through the VPN | Off the VPN | Off the VPN |
| VPN failure | Status polling | Firewall block | Firewall block + 1 s watchdog |
| Cost | Free | US$19 app | Free (MIT + upstream sources) |
| Maintenance | Exclusion list | — | None |

**Empirical test on the test Mac:** with Mullvad connected and `/usr/bin/curl`
in its exclusion list, `curl` **still went out through Mullvad**. The exclusion
list was not reliable for this use, and its model is the inverse of what was
needed, so that approach was dropped.

From the VPNonly repository (commit `50d3627`) **only** what adds value was reused:

* `wireguard-go-nat.patch` (MIT) — essential for Mullvad (see §2), applied
  unchanged and with its tests.
* `vpnrun.c` (MIT) — adapted: fixed group, program allow-list (apps.conf), keeps
  the user's supplementary groups, new session so it survives sudo's pty.
* The idea of a per-group PF anchor with `route-to` and a final block rule.

Not used: the NordVPN logic, profiles, the Swift parser, the `vpnonly` CLI
(NordVPN only), or anything from the commercial app or the website.

## 2. Audit of VPNonly's engine

**Architecture** (`app-engine/`): `group.sh` creates one Unix group per app
(GID 7100–7899); `run.sh` + `vpnrun` launch the app as the user but with that
group; `up.sh` starts `wireguard-go -f utun` (free interface), configures the
peer with `wg setconf` from a 0600 file and assigns the address without touching
the default route; `route.sh` loads into the `com.apple/vpnonly` anchor:

```
pass  out quick on ! lo0 route-to (utunN TUNNEL_IP) inet proto { tcp udp } from any to any group G keep state
block return out quick on ! lo0 from any to any group G
```

PF identifies the group of each socket, so **all child processes** (which
inherit the group) are covered. `down.sh` switches to block-only before tearing
the tunnel down. Very defensive code (root-only 0600 state, exact PID and
command checks, PF tokens, anchor rollback).

**Relevant findings:**

* **DNS is not tunneled** (its README says so): apps resolve through
  `mDNSResponder`, which does not carry the group.
* It warns that the official Mullvad client **may disable PF** when it
  disconnects, taking the per-app rules with it. VPNonly fixes it "within a
  minute"; here a watchdog checks every second and freezes (SIGSTOP) protected
  apps while it repairs.
* The NAT patch: on macOS, PF does not apply `nat` rules to packets diverted with
  `route-to`, so they reach the tunnel with the LAN address as source. Mullvad
  enforces strict cryptokey routing and drops them. The patch rewrites the inner
  source to the tunnel address and reverses it on replies (bounded, expiring
  flow table; unparseable packets are passed through untouched). Reviewed; its
  tests pass with Go 1.26.10.
* Inherent design limit that remains: processes macOS launches through
  `launchd`/XPC **do not inherit the group** (see §4).

## 3. Licenses

| Component | License | Use |
|---|---|---|
| Own code (vsctl, app, launchers, installer) | MIT | — |
| `vpnrun.c` (derived) and `wireguard-go-nat.patch` from VPNonly | MIT © 2026 Kanishk Razdan | Attribution in the code and in `third_party/licenses/VPNonly-engine-MIT.txt` |
| wireguard-go 0.0.20250522 | MIT © WireGuard LLC | Built here with the patch |
| wireguard-tools (`wg`) 1.0.20260223 | GPL-2.0 | Built here **unmodified**; text in `third_party/licenses/` |
| VPNonly app, website, videos, zips in its `docs/` | All rights reserved | **Nothing used or redistributed** |

This kit **ships no binaries**: `src/build.sh` downloads the official sources,
verifies their SHA-256 (the same ones VPNonly pins for WireGuard; Go's from
go.dev) and compiles on the Mac itself. If you ever redistribute `build/`, the
GPL-2.0 of `wg` requires offering its source code (link in the notices).

## 4. Architecture and helper processes

```
 Protected apps ──(group vpnselectivo, inherited by children)──┐
                                                               │  PF anchor com.apple/vpnselectivo
 Rest of the Mac ──(normal group)──► normal route              │  route-to ──► utunN (wireguard-go + NAT)
                                                               │                 └─► Mullvad (encrypted UDP)
                                    anything else from the group ──► BLOCKED (IPv6, ICMP, tunnel down)
```

* **`vsctl _daemon`** (root LaunchDaemon, 1 s tick): sole owner of the tunnel and
  of PF. Brings the tunnel up on demand (switch or Auto-VPN apps), takes it down
  120 s after the last Auto-VPN app closes, reconnects with backoff, repairs PF,
  terminates apps launched outside the VPN, checks the real exit IP in the
  background and writes `/var/run/vpnselectivo/status.json`.
* **`vsctl`** (through sudoers, passwordless only for specific commands;
  `import` requires a password). Validates every argument; never reads user
  files as root.
* **`vpnrun`** (root, 0700): `initgroups` + `setgid(vpnselectivo)` +
  `setuid(user)`, verifies the privilege drop, `setsid`, and `posix_spawn` with
  *responsibility disclaim* (camera/microphone permissions attributed to the app).
* **App** (Swift; SwiftUI control window + menu-bar shield, LaunchAgent): status,
  VPN switch, location, Auto-VPN, check/uncheck apps; detects instantly (KVO on
  `NSWorkspace`) a protected app opened outside the VPN, terminates it and
  reopens it protected (`--restore-last-session` for Chromium).
* **Dock launchers**: one "‹App› VPN" per entry in `apps.conf`.

**Real executables identified (reference setup):**

| App | Process | How it is protected |
|---|---|---|
| Stremio 2.1.0 (`com.stremio.pal`, Mac Catalyst, App Sandbox) | `Contents/MacOS/Stremio` | launched by `vpnrun` |
| Torrent engine | `Contents/Resources/node` (v18) `server.js` — **child** of Stremio | inherits the group |
| Brave | `Contents/MacOS/Brave Browser` + helpers (renderer/GPU/plugin/network) | inherit the group |
| Brave crashpad | `chrome_crashpad_handler` (detaches, ppid 1) | still inherits the group |
| A user-made Automator launcher for Brave's private window | runs `open -a "Brave Browser" --args --incognito` | **not a separate app**: it is the same Brave. If used, `--incognito` is detected, Brave is closed and reopened protected in private mode |
| BraveUpdater, Helper (Alerts) | launched by macOS | excluded from termination (not browsing) |

**What no per-process method can cover** (Mullvad's split tunneling included):
services macOS launches through `launchd`/XPC on behalf of the app, which do not
inherit the group. In Stremio 2.1.0 (an iPad app on the Mac) these are
`WKWebView` → `com.apple.WebKit.Networking`, `AVPlayer` and background
`URLSession` → `nsurlsessiond`, and DNS resolution → `mDNSResponder`. The
**torrent engine (`node`) and the app's own networking do go through the tunnel**;
torrent playback arrives over `127.0.0.1` from `node`. The `leakwatch` test
measures exactly this (see §7).

## 5. Leaks and failure handling

| Vector | Handling |
|---|---|
| IPv4 TCP/UDP of protected apps, their engines and helpers | `route-to` into the tunnel (torrent TCP, uTP/UDP, DHT, trackers, WebRTC, QUIC) |
| IPv6 | Blocked for the group (apps fall back to IPv4) |
| ICMP and other protocols | Blocked for the group |
| Tunnel down / `wireguard-go` dead | Packets diverted to a missing interface are dropped; the daemon switches to **block-only** within ≤1 s and reconnects. The normal route is never used |
| Unresponsive server | Traffic is still forced into the tunnel → no connectivity, no leak |
| PF disabled by another program (e.g. the official Mullvad client on disconnect) | ≤1 s: **SIGSTOP** protected processes (nothing is closed, no tabs lost), PF re-enabled, rules reloaded and verified, **SIGCONT**. Residual window ≤1 s |
| Anchor altered or deleted | Same as above (compared with the expected rules every second) |
| Protected apps opened outside the VPN (Dock, Spotlight, links, auto-update, login) | App: terminated as soon as it registers with LaunchServices and reopened protected. Daemon: 1 s sweep as backup |
| Checking an app that is already running | Grace period: it is not terminated until it is restarted (cleanly, from the UI) or closed |
| DNS | Apps resolving through `mDNSResponder` → **the system resolver sees hostnames** (not IPs or content). Brave: with the optional profile, resolved at Mullvad |
| Local network (router, UPnP/NAT-PMP, SSDP, LSD) | **Blocked** by default (casting to a TV doesn't work). `ALLOW_LAN=1` allows the local subnet but blocks the router |
| Mullvad's internal SOCKS proxy over a physical link | Blocked (prevents an "outside" Brave with the optional policy from leaking hostnames) |

**Switching off never closes anything:** with the VPN off, protected apps stay
open but blocked until the VPN is back. This resolves the tension between
security and keeping browser tabs: a protected app is never killed because of a
VPN failure, and never goes out without the VPN.

**Optional Brave layer** (`src/brave-profile.sh`, offered by the installer): a
configuration profile forcing `socks5://10.64.0.1:1080`. That proxy only exists
inside a Mullvad tunnel → even if Brave were opened outside, it would have no
connection, and its DNS is resolved at Mullvad. Cost: Brave shows "Managed by
your organization", HTTP/3 is disabled, and Brave depends on Mullvad's proxy.
Removed in System Settings › General › Device Management.

## 6. Official Mullvad client, WireGuard and the firewall

* No setting of the official Mullvad client is modified (split tunneling,
  exclusions, account). The installer only **informs**.
* A **separate WireGuard configuration** from the account is needed
  (mullvad.net › WireGuard configuration; uses 1 of 5 devices). The private key
  is stored in `/Library/VPNSelectivo/etc/servers/*.conf` (root, 0600),
  normalized (key, tunnel address, server key, endpoint only; `PostUp` and the
  like are discarded). It never appears in process arguments.
* Use **one or the other**: while the official client is connected, the whole
  Mac goes through Mullvad; VPN Selectivo keeps working (nested tunnel) and shows
  a warning. When the official client disconnects it may disable PF; the daemon
  repairs it within ≤1 s.
* Differences from the official app: no quantum resistance or DAITA (proprietary
  extensions of the official client); standard WireGuard (Curve25519/ChaCha20).
* Does not interfere with other VPN clients (e.g. the WireGuard app): it never
  touches their utun interfaces, routes or profiles, and never identifies its own
  tunnel by interface name.
* PF: enabled with **its own reference** (`pfctl -E` token), and only the
  `com.apple/vpnselectivo` anchor is written. Apple's main ruleset
  (`/etc/pf.conf`) is only loaded if the main ruleset is empty.

## 7. Tests

### Static (no privileges)

* WireGuard sources: SHA-256 match the values pinned by VPNonly.
* NAT patch `go test`: OK. `wg`, `vpnrun`, the app and the launchers build.
* `tests/unit.sh`: **70/70** — Mullvad config parser (CRLF, IPv6 endpoint
  rejected, invalid keys, `PostUp` discarded), PF rules (route-to before block,
  SOCKS guard, LAN with router blocked, CGNAT excluded, tampered interface name
  rejected), relay-list validation and weighted selection, `apps.conf` parsing
  (tampered lines rejected), outside-launch detection (Brave, crashpad, helpers,
  `node`; updater, notifications, other apps and other users untouched), grace
  periods (including children of a graced process), Auto-VPN global/per app.
  The tests found and fixed 2 real parser bugs before installation.
* `shellcheck` 0.11: no warnings. `visudo -c` on the rule: OK. Plists: OK.

### Live (installed) — `tests/live-tests.sh` or control window › *Autodiagnóstico*

1. PF enabled, `com.apple/*` hook and anchor intact.
2. Protected process → `am.i.mullvad.net` reports `mullvad_exit_ip: true`.
3. Normal process → `false`, different IP.
4. IPv6 blocked for the group (or N/A if the network has no IPv6).
5. UDP through the tunnel (OpenDNS on UDP 443 sees the Mullvad IP).
6. **Kill switch**: `wireguard-go` killed with SIGKILL → the protected process
   gets no answer (or only via Mullvad after reconnecting); automatic reconnect.
7. All processes of protected apps carry the group.
8. `leakwatch`: PKTAP capture on the physical interfaces of any packet attributed
   to protected processes **or to services acting on their behalf (epid)**
   outside the tunnel, while browsing and streaming.

### Live results (October 2026)

| Test | Result |
|---|---|
| PF enabled, hook, anchor intact | OK |
| Protected process → Mullvad exit | OK |
| Normal process → ISP's direct IP, different | OK |
| All 14 Brave processes (incl. detached crashpad) in the group | OK |
| Stremio and its `node` in the group | OK |
| Brave browsing 3 pages (YouTube, a WebRTC test): TCP/UDP outside the tunnel | **0 packets** |
| Stremio torrent engine (Big Buck Bunny, CC): 55 peers, UDP trackers answering; swarm traffic outside the tunnel | **0 packets** |
| PF counters after real use | route-to: 8,227 TCP + 8,609 UDP packets (7.7 MB) |
| Kill switch: `wireguard-go` SIGKILLed while Brave reloaded pages every 3 s | **0 packets** outside the tunnel; reconnected in 4 s |
| Brave, the Automator private-window launcher and Stremio opened outside the VPN | Terminated in <1 s, reopened protected in ~2 s; **0 packets** sent by the unprotected instances |
| VPN switched off with Brave and Stremio open | Still open, traffic blocked (400 packets rejected by the block rule), **0 leaks**; other apps kept the direct IP |
| Daemon restart with protected apps open | Tunnel stayed up; no interruption |
| DNS | `mDNSResponder` asks the local router for the hostnames requested by Brave and `node` — **expected limit** (§9) |
| **Finding:** Brave's mDNS multicast (224.0.0.251 / ff02::fb :5353) on en0 | PF cannot attribute it to Brave (port shared with `mDNSResponder` via SO_REUSEPORT). Never leaves the local network. Mitigation: `EnableMediaRouter=false` in the optional profile |
| IPv6 | The test network had **no global IPv6** (link-local only): no leak path; the IPv6 block rule is loaded |
| Test design | The first UDP test used `whoami.cloudflare` (CH class), which the test network dropped even without the VPN; replaced with OpenDNS on UDP 443. Apple's `tcpdump -Q` parser rejects mixing quoted names with several `pid=` terms; fixed with two parallel captures |

**Location selection:** public relay list downloaded as root (553 servers, 50
countries, 0 rejected by validation). Switching with Brave and Stremio open:
`us` → us-atl-wg-404 (3 s), `de-fra` → de-fra-wg-103 (2 s), `se-mma-wg-001`
(1 s), `us-nyc` → us-nyc-wg-301; `check-ip` confirmed the Mullvad exit country
each time while other apps kept the direct IP. Leak watch during two switches
with Brave loading pages: **0 leaks** (DNS only).

**Configurable apps:** automatic migration of an earlier install to `apps.conf`
without interrupting the tunnel. Test with a new app, **Microsoft Edge**:
`app-add` created the "Microsoft Edge VPN" launcher; opened with it, its 10
processes carried the group and the leak watch showed **0 leaks**; opened
outside the VPN (LaunchServices), the app terminated it instantly and reopened it
protected in 2 s; after `app-remove`, Edge opened with its normal connection and
was left alone. Fixed finding: the app did not reload `apps.conf` on change (it
now watches it every second).

**Control window, VPN switch and Auto-VPN**, all passwordless: switch OFF with
Brave and Stremio open → tunnel down, apps open but blocked; ON → reconnection
with the exit IP shown in the status. Auto-VPN: after a manual OFF, opening Brave
(⚡) turns the tunnel back on; with global Auto-VPN off, or Stremio without ⚡,
opening them does not, and they warn that they will stay offline. Checking Edge
**while it was running**: grace period (8 processes), not terminated; "restart
now" reopened it with its 9 processes in the tunnel and the grace entry cleared
itself. Unchecking it while running: it stayed in the tunnel until restarted;
afterwards, normal connection. In the window (screenshots): status, exit IP,
routed apps, location pickers, "checked only" filter, and checking/unchecking an
app with its switch created and removed its launcher. Fixed finding: Automator
launchers (`com.apple.automator.*`) were shown as "Apple app"; they now explain
they just open another app.

**Not yet tested:** connecting/disconnecting the official Mullvad client with
protected apps open (live PF repair) and sleep/wake.

## 8. Location selection (country, city, server)

All WireGuard configurations of a Mullvad account share the same private key and
tunnel address; only the server changes. So **one** imported configuration is
enough, plus **Mullvad's public relay list**
(`api.mullvad.net/public/relays/wireguard/v2/`, no account needed), downloaded at
install time and refreshed every 7 days. Every field is validated before use and
a list with fewer than 50 valid servers is rejected.

* **Country or city (automatic):** a random active server, weighted like the
  official app; if one doesn't answer, up to 3 are tried.
* **Specific server:** only that one; if it doesn't answer, protected apps stay
  offline (it never switches country on its own).
* Switching drops protected apps' open connections for a few seconds and they
  reconnect through the new server; they stay blocked during the switch.
* From Terminal: `sudo /Library/VPNSelectivo/bin/vsctl select us` (or `us-nyc`,
  `us-nyc-wg-301`).

## 9. What cannot be guaranteed

1. **System services acting on behalf of an app** (WebKit, `nsurlsessiond`,
   possibly out-of-process `AVPlayer`, DNS via `mDNSResponder`) bypass the VPN.
   This affects embedded web pages, background downloads and hostnames — **not**
   `node`'s torrent traffic. Measurable with `leakwatch`.
2. **DNS**: the system resolver sees the hostnames apps look up (trackers,
   add-ons). If that matters, install Mullvad's official encrypted DNS profile
   for the whole Mac (github.com/mullvad/encrypted-dns-profiles) — it affects all
   apps.
3. **≤1 s window** if another program disables PF: until apps are frozen, the
   kernel may retransmit an in-flight TCP segment through the normal route.
4. **Outside launches**: between a protected app starting from its original icon
   and its termination there are milliseconds (app running) or ≤1 s (daemon
   only). The optional Brave layer closes that gap for Brave.
5. A browser opened outside the VPN through a link (default browser) is reopened
   protected **without** that link.
6. With `ALLOW_LAN=0`, protected apps cannot cast to Chromecast/AirPlay or
   receive from the local network.
7. Mullvad IPv4 endpoints only; IPv4 only inside the tunnel.
8. Not audited by a third party. The code is small and readable so you can
   review it: `src/engine/vsctl` (~1,200 lines), `vpnrun.c` (~170), the app
   (~1,150 lines of Swift).
