// VPN Selectivo — ventana de control (SwiftUI), accesible desde el Dock.
//
// Interruptor maestro, estado en vivo (servidor, IP de salida, apps enrutadas),
// selector de país/ciudad/servidor, Auto-VPN global y por app, y la lista de
// apps de /Applications para marcarlas (por la VPN) o desmarcarlas (conexión
// normal). Todo pasa por `sudo -n vsctl …` (regla sudoers sin contraseña).
import AppKit
import SwiftUI

let GRACE_PATH = "/var/run/vpnselectivo/grace"

// App de /Applications o ~/Applications que se puede marcar.
struct InstalledApp: Identifiable {
    let path: String, name: String, bundleID: String?, icon: NSImage, unsupported: String?
    var id: String { path }
}

func scanInstalledApps() -> [InstalledApp] {
    let fm = FileManager.default
    var out: [InstalledApp] = []
    for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for item in items where item.hasSuffix(".app") {
            let path = dir + "/" + item
            let b = Bundle(path: path)
            let bid = b?.bundleIdentifier
            let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? String(item.dropLast(4))
            var why: String?
            if let bid = bid, bid.hasPrefix("com.apple.automator.") {
                why = L("Automator launcher: it only opens another app. Check the app it opens (e.g. Brave) and use its VPN launcher.", "Lanzador de Automator: solo abre otra app. Marca la app que abre (p. ej. Brave) y usa su acceso VPN.")
            } else if let bid = bid, bid.hasPrefix("com.apple.") {
                why = L("Apple app: it connects through system services, which cannot go through the tunnel.", "App de Apple: hace su conexión mediante servicios del sistema, que no pueden ir por el túnel.")
            } else if let bid = bid, ["net.mullvad", "com.wireguard", "ch.protonvpn", "com.nordvpn", "com.expressvpn", "com.tunnelbear", "com.cisco.anyconnect", "com.paloaltonetworks", "com.fortinet", "local.vpnselectivo"].contains(where: bid.hasPrefix) {
                why = L("It is a VPN, or part of VPN Selectivo.", "Es una VPN o parte de VPN Selectivo.")
            } else if bid == nil {
                why = L("Not a valid app.", "No es una app válida.")
            }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 32, height: 32)
            out.append(InstalledApp(path: path, name: name, bundleID: bid, icon: icon, unsupported: why))
        }
    }
    return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

// id para apps.conf a partir del nombre ("Microsoft Edge" → "microsoft-edge").
func appSlug(_ name: String, taken: [String]) -> String {
    var id = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    while id.contains("--") { id = id.replacingOccurrences(of: "--", with: "-") }
    id = String(id.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(28))
    if id.isEmpty { id = "app" }
    var n = 2; let base = id
    while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
    return id
}

func cleanName(_ s: String) -> String {
    String(s.filter { !"\"'\\$`/|<>;&".contains($0) }.prefix(40))
}

enum RunState {
    case tunnel, blocked, pendingIn, pendingOut, direct
    var text: String {
        switch self {
        case .tunnel: return L("Open · via Mullvad", "Abierta · por Mullvad")
        case .blocked: return L("Open · no Internet (VPN off)", "Abierta · sin Internet (VPN apagada)")
        case .pendingIn: return L("Open without VPN · restart it to protect it", "Abierta sin VPN · reiníciala para protegerla")
        case .pendingOut: return L("Still in the tunnel · restart it to take it out", "Aún en el túnel · reiníciala para sacarla")
        case .direct: return L("Open · normal connection", "Abierta · conexión normal")
        }
    }
    var color: Color {
        switch self {
        case .tunnel: return .green
        case .blocked: return .red
        case .pendingIn, .pendingOut: return .orange
        case .direct: return .secondary
        }
    }
}

final class ControlModel: ObservableObject {
    @Published var status: Status?
    @Published var fresh = false
    @Published var apps: [AppEntry] = []
    @Published var relays: [Relay] = []
    @Published var installed: [InstalledApp] = []
    @Published var runStates: [String: RunState] = [:]   // por ruta de la app
    @Published var busy: String?
    @Published var message = ""
    weak var delegate: AppDelegate?
    let work = DispatchQueue(label: "vpnselectivo.ui")

    // ── estado derivado ───────────────────────────────────────────────────
    var tunnelUp: Bool { status?.tunnel == "up" || status?.tunnel == "stale" }
    var masterOn: Bool { tunnelUp || (status?.manual_on ?? false) }
    var autoVPN: Bool { (status?.auto_vpn ?? 1) == 1 }
    func isProtected(_ path: String) -> Bool { apps.contains { $0.path == path } }
    func entries(_ path: String) -> [AppEntry] { apps.filter { $0.path == path } }
    func isAuto(_ path: String) -> Bool { entries(path).contains { $0.auto } }

    var headline: (String, String, Color) {
        guard let s = status, fresh else { return (L("Service unavailable", "Servicio no disponible"), "exclamationmark.triangle.fill", .orange) }
        if s.pf == "broken" { return (L("Firewall altered: protected apps frozen", "Cortafuegos alterado: apps protegidas congeladas"), "exclamationmark.shield.fill", .red) }
        if !s.configured { return (L("Mullvad configuration missing", "Falta la configuración de Mullvad"), "exclamationmark.shield.fill", .orange) }
        switch s.tunnel {
        case "up": return (L("Connected", "Conectado"), "lock.shield.fill", .green)
        case "stale": return (L("Server not responding", "Servidor sin respuesta"), "shield.lefthalf.filled", .orange)
        default:
            if (s.manual_on ?? false) { return (L("Connecting…", "Conectando…"), "shield.lefthalf.filled", .orange) }
            return (L("Disconnected", "Desconectado"), "shield.slash", .secondary)
        }
    }

    var detail: String {
        guard let s = status, fresh else { return L("Check that VPN Selectivo is installed.", "Comprueba que VPN Selectivo esté instalado.") }
        if tunnelUp {
            var parts: [String] = []
            if let r = relays.first(where: { $0.host == s.server }) {
                parts.append("\(flag(r.cc)) \(r.country), \(r.city)")
            }
            parts.append(s.server)
            if let ip = s.exit_ip, !ip.isEmpty { parts.append("IP \(ip)") }
            return parts.joined(separator: " · ")
        }
        return (s.manual_down) ? L("Switched off manually: checked apps have no Internet access.", "Apagada a mano: las apps marcadas no tienen Internet.")
            : (autoVPN ? L("It will turn on when you open an app with ⚡.", "Se encenderá al abrir una app con ⚡.") : L("Auto-VPN is off: turn the VPN on with the switch.", "Auto-VPN desactivado: enciéndela con el interruptor."))
    }

    var routedSummary: String {
        let names = installed.filter { runStates[$0.path] == .tunnel }.map { $0.name }
        if !names.isEmpty { return L("Through the tunnel now: ", "Por el túnel ahora: ") + names.joined(separator: ", ") }
        let blocked = installed.filter { runStates[$0.path] == .blocked }.map { $0.name }
        if !blocked.isEmpty { return L("No Internet (VPN off): ", "Sin Internet (VPN apagada): ") + blocked.joined(separator: ", ") }
        return L("No checked app is open.", "Ninguna app marcada está abierta.")
    }

    // ── actualización (cada segundo, desde AppDelegate.refresh) ─────────────
    func updateRunStates() {
        guard let gid = vpnGroupID() else { return }
        var states: [String: RunState] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let path = app.bundleURL?.path, let rgid = procRealGID(app.processIdentifier) else { continue }
            let inGroup = rgid == gid
            let prot = isProtected(path)
            let st: RunState
            switch (prot, inGroup) {
            case (true, true): st = tunnelUp ? .tunnel : .blocked
            case (true, false): st = .pendingIn
            case (false, true): st = .pendingOut
            case (false, false): st = .direct
            }
            states[path] = st
        }
        if states.mapValues({ "\($0)" }) != runStates.mapValues({ "\($0)" }) { runStates = states }
    }

    func rescan() { installed = scanInstalledApps() }

    // ── acciones ──────────────────────────────────────────────────────────
    private func run(_ label: String, _ job: @escaping () -> (ok: Bool, out: String), done: ((Bool) -> Void)? = nil) {
        busy = label
        work.async {
            let r = job()
            DispatchQueue.main.async {
                self.busy = nil
                self.message = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n").filter { !$0.isEmpty }.last ?? ""
                self.delegate?.refresh()
                done?(r.ok)
            }
        }
    }

    func setVPN(_ on: Bool) {
        run(on ? L("Connecting…", "Conectando…") : L("Disconnecting…", "Desconectando…")) { runVsctl(on ? ["connect"] : ["disconnect"]) }
    }

    func setGlobalAuto(_ on: Bool) {
        run(L("Saving…", "Guardando…")) { runVsctl(["set-auto", on ? "on" : "off"]) }
    }

    func select(_ code: String) {
        guard !code.isEmpty, code != status?.selected else { return }
        run(L("Switching to ", "Cambiando a ") + (delegate?.describe(code) ?? code) + "…") { runVsctl(["select", code]) }
    }

    func setAuto(_ app: InstalledApp, _ on: Bool) {
        guard let e = entries(app.path).first else { return }
        run(L("Saving…", "Guardando…")) { runVsctl(["app-auto", e.id, on ? "1" : "0"]) }
    }

    func setProtected(_ app: InstalledApp, _ on: Bool) {
        if let why = app.unsupported, on { alert(L("\(app.name) cannot be protected", "No se puede proteger \(app.name)"), why); return }
        let state = runStates[app.path]
        if on {
            let id = appSlug(app.name, taken: apps.map { $0.id })
            var restart = false
            if state == .direct {
                restart = ask(L("\(app.name) is open without the VPN", "\(app.name) está abierta sin VPN"),
                              L("For its traffic to go through Mullvad it must be restarted (it quits cleanly and reopens protected). If you choose “When I quit it”, it keeps your normal connection until you quit it.", "Para que su tráfico vaya por Mullvad hay que reiniciarla (se cierra de forma ordenada y se reabre protegida). Si eliges «Al cerrarla», seguirá usando tu conexión normal hasta que la cierres."),
                              L("Restart Now", "Reiniciar ahora"), L("When I Quit It", "Al cerrarla"))
            }
            run(L("Protecting \(app.name)…", "Protegiendo \(app.name)…")) {
                var r = runVsctl(["app-add", id, cleanName(app.name), app.path])
                if r.ok && restart {
                    if quitGracefully(app.path) { r = runVsctl(["launch", id, "--restore"]) }
                    else { r.out += "\n" + L("\(app.name) did not quit: quit it yourself (Cmd+Q) and open it again.", "\(app.name) no se cerró: ciérrala tú (Cmd+Q) y ábrela de nuevo.") }
                }
                return r
            }
        } else {
            let es = entries(app.path)
            if es.count > 1 && !ask(L("Stop protecting \(app.name)?", "¿Dejar de proteger \(app.name)?"),
                                    L("Its launchers will be removed too: ", "También se quitarán sus accesos: ") + es.map { $0.name }.joined(separator: ", ") + ".",
                                    L("Remove", "Quitar"), L("Cancel", "Cancelar")) { return }
            var restart = false
            if state == .tunnel || state == .blocked {
                restart = ask(L("\(app.name) is still inside the tunnel", "\(app.name) sigue dentro del túnel"),
                              L("While it stays open, its traffic keeps going through Mullvad (or stays blocked if the VPN is off). Restart it so it uses your normal connection.", "Mientras siga abierta, su tráfico continúa por Mullvad (o bloqueado si la VPN está apagada). Reiníciala para que use tu conexión normal."),
                              L("Restart Now", "Reiniciar ahora"), L("When I Quit It", "Al cerrarla"))
            }
            run(L("Removing \(app.name)…", "Quitando \(app.name)…")) {
                var r: (ok: Bool, out: String) = (true, "")
                for e in es { r = runVsctl(["app-remove", e.id]); if !r.ok { return r } }
                if restart {
                    if quitGracefully(app.path) {
                        DispatchQueue.main.sync {
                            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path),
                                                               configuration: NSWorkspace.OpenConfiguration())
                        }
                        r.out += "\n" + L("\(app.name) reopened with your normal connection.", "\(app.name) reabierta con tu conexión normal.")
                    } else { r.out += "\n" + L("\(app.name) did not quit: quit it yourself (Cmd+Q).", "\(app.name) no se cerró: ciérrala tú (Cmd+Q).") }
                }
                return r
            }
        }
    }
}

// Cierre ordenado (como Cmd+Q) de todas las instancias de una app. Fuera del hilo principal.
func quitGracefully(_ path: String) -> Bool {
    let running: [NSRunningApplication] = DispatchQueue.main.sync {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
    }
    if running.isEmpty { return true }
    DispatchQueue.main.sync { running.forEach { _ = $0.terminate() } }
    for _ in 0..<150 {
        if running.allSatisfy({ $0.isTerminated }) { usleep(500_000); return true }
        usleep(100_000)
    }
    return false
}

func ask(_ title: String, _ text: String, _ yes: String, _ no: String) -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.addButton(withTitle: yes); a.addButton(withTitle: no)
    NSApp.activate(ignoringOtherApps: true)
    return a.runModal() == .alertFirstButtonReturn
}

func alert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
}

// ── vistas ────────────────────────────────────────────────────────────────
struct ControlView: View {
    @ObservedObject var m: ControlModel
    @State private var search = ""
    @State private var onlyProtected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                location
                Toggle(isOn: Binding(get: { m.autoVPN }, set: { m.setGlobalAuto($0) })) {
                    Text(L("Auto-VPN: turn on when an app with ⚡ opens, and off 2 min after they are closed", "Auto-VPN: encender al abrir una app con ⚡ y apagar 2 min después de cerrarlas"))
                }
                .toggleStyle(.switch).disabled(!m.fresh)
                warnings
            }
            .padding(16)
            Divider()
            appsHeader.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            List(filtered) { app in AppRow(m: m, app: app) }
                .listStyle(.inset)
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 660, minHeight: 620)
        .onAppear { if m.installed.isEmpty { m.rescan() } }
    }

    var header: some View {
        let (title, symbol, color) = m.headline
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundColor(color).frame(width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2).bold()
                Text(m.detail).foregroundColor(.secondary).lineLimit(1)
                Text(m.routedSummary).font(.callout).lineLimit(2)
            }
            Spacer()
            if let b = m.busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(b).font(.callout).foregroundColor(.secondary) }
            }
            VStack(spacing: 2) {
                Toggle("", isOn: Binding(get: { m.masterOn }, set: { m.setVPN($0) }))
                    .toggleStyle(.switch).controlSize(.large).labelsHidden()
                    .disabled(!m.fresh || m.busy != nil || !(m.status?.configured ?? false))
                Text("VPN").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // País › ciudad › servidor, derivados de lo elegido ("us", "us-nyc", "us-nyc-wg-301").
    var location: some View {
        let sel = m.status?.selected ?? ""
        let cc = String(sel.prefix(2))
        let loc = sel.count >= 6 ? String(sel.prefix(6)) : ""
        let host = sel.contains("-wg-") ? sel : ""
        let countries = Dictionary(grouping: m.relays, by: { $0.cc })
            .map { ($0.key, $0.value[0].country) }.sorted { $0.1 < $1.1 }
        let cities = Dictionary(grouping: m.relays.filter { $0.cc == cc }, by: { $0.loc })
            .map { ($0.key, $0.value[0].city) }.sorted { $0.1 < $1.1 }
        let servers = m.relays.filter { $0.loc == loc && $0.active }.map { $0.host }.sorted()
        return HStack(spacing: 8) {
            Text(L("Location", "Ubicación")).frame(width: 80, alignment: .leading)
            Picker("", selection: Binding(get: { cc }, set: { m.select($0) })) {
                if !countries.contains(where: { $0.0 == cc }) { Text(sel.isEmpty ? "—" : sel).tag(cc) }
                ForEach(countries, id: \.0) { c in Text("\(flag(c.0))  \(c.1)").tag(c.0) }
            }.labelsHidden().frame(width: 210)
            Picker("", selection: Binding(get: { loc }, set: { m.select($0.isEmpty ? cc : $0) })) {
                Text(L("Any city", "Cualquier ciudad")).tag("")
                ForEach(cities, id: \.0) { c in Text(c.1).tag(c.0) }
            }.labelsHidden().frame(width: 190).disabled(cities.isEmpty)
            Picker("", selection: Binding(get: { host }, set: { m.select($0.isEmpty ? loc : $0) })) {
                Text(L("Automatic server", "Servidor automático")).tag("")
                ForEach(servers, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 170).disabled(loc.isEmpty)
        }
        .disabled(m.relays.isEmpty || m.busy != nil)
    }

    @ViewBuilder var warnings: some View {
        if let s = m.status, m.fresh {
            if s.official_mullvad == "Connected" || s.official_mullvad == "Connecting" {
                Label(L("The official Mullvad app is connected: your whole Mac goes through the VPN.", "El cliente oficial de Mullvad está conectado: todo el Mac va por la VPN."), systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange).font(.callout)
            }
            if !s.configured {
                Label(L("Import your Mullvad WireGuard configuration (button below).", "Importa tu configuración WireGuard de Mullvad (botón abajo)."), systemImage: "key")
                    .foregroundColor(.orange).font(.callout)
            }
        }
    }

    var filtered: [InstalledApp] {
        m.installed.filter { app in
            (!onlyProtected || m.isProtected(app.path)) &&
            (search.isEmpty || app.name.localizedCaseInsensitiveContains(search))
        }
    }

    var appsHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apps").font(.headline)
                Text(L("Checked: its traffic (and that of its helper processes) goes through Mullvad. Unchecked: normal connection.", "Marcadas: su tráfico (y el de sus procesos auxiliares) va por Mullvad. Desmarcadas: conexión normal."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Toggle(L("Checked only", "Solo marcadas"), isOn: $onlyProtected).toggleStyle(.checkbox)
            TextField(L("Search", "Buscar"), text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
            Button { m.rescan() } label: { Image(systemName: "arrow.clockwise") }.help(L("Re-read /Applications", "Volver a leer /Applications"))
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            Button(L("Check IP", "Comprobar IP")) { m.delegate?.checkIP() }
            Button(L("Self-Test", "Autodiagnóstico")) { m.delegate?.selftest() }
            Button(L("Watch for Leaks", "Vigilar fugas")) { m.delegate?.leakwatch() }
            Button(L("Import Configuration…", "Importar configuración…")) { m.delegate?.importConfig() }
            Button(L("Log", "Registro")) { m.delegate?.openLog() }
            Spacer()
            Text(m.message).font(.caption).foregroundColor(.secondary).lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
        }
    }
}

struct AppRow: View {
    @ObservedObject var m: ControlModel
    let app: InstalledApp

    var body: some View {
        let prot = m.isProtected(app.path)
        let state = m.runStates[app.path]
        let variants = m.entries(app.path).filter { !$0.args.isEmpty }
        return HStack(spacing: 10) {
            Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).fontWeight(prot ? .semibold : .regular)
                    if !variants.isEmpty {
                        Text("+ " + variants.map { $0.name }.joined(separator: ", "))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                if let st = state { Text(st.text).font(.caption).foregroundColor(st.color) }
                else if let why = app.unsupported { Text(why).font(.caption).foregroundColor(.secondary).lineLimit(1) }
            }
            Spacer()
            if prot && state == .pendingIn {
                Button(L("Restart", "Reiniciar")) { m.setProtected(app, true) }.controlSize(.small)
                    .help(L("Quits the app cleanly and reopens it inside the tunnel", "Cierra la app de forma ordenada y la reabre dentro del túnel"))
            }
            Toggle("⚡", isOn: Binding(get: { m.isAuto(app.path) }, set: { m.setAuto(app, $0) }))
                .toggleStyle(.checkbox)
                .disabled(!prot || !m.autoVPN || m.busy != nil)
                .help(L("Auto-VPN: opening this app turns the VPN on; closing it turns it off (after 2 min)", "Auto-VPN: abrir esta app enciende la VPN y cerrarla la apaga (tras 2 min)"))
            Toggle("", isOn: Binding(get: { prot }, set: { m.setProtected(app, $0) }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(app.unsupported != nil || m.busy != nil || !m.fresh)
                .help(prot ? L("Checked: goes through Mullvad", "Marcada: va por Mullvad") : L("Unchecked: normal connection", "Desmarcada: conexión normal"))
        }
        .padding(.vertical, 2)
        .opacity(app.unsupported != nil ? 0.55 : 1)
    }
}

// Ventana (una sola; se oculta al cerrarla, la app sigue en el Dock).
final class ControlWindowController: NSWindowController, NSWindowDelegate {
    convenience init(model: ControlModel) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "VPN Selectivo"
        w.contentView = NSHostingView(rootView: ControlView(m: model))
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("VPNSelectivoControl")
        w.center()
        self.init(window: w)
        w.delegate = self
    }
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
