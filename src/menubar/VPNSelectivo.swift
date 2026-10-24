// VPN Selectivo — app de barra de menú.
//
// Muestra el estado que escribe el daemon root (/var/run/vpnselectivo/
// status.json), abre las apps protegidas (etc/apps.conf) dentro de la VPN mediante
// `sudo -n vsctl launch …` (regla sudoers limitada), y vigila al instante los
// lanzamientos de apps protegidas hechos "por fuera" (Dock, Spotlight, enlaces,
// actualizaciones): los termina y los reabre protegidos. El daemon hace lo
// mismo cada segundo como respaldo, aunque esta app no esté abierta.
import AppKit
import UniformTypeIdentifiers
import UserNotifications

let VSCTL = "/Library/VPNSelectivo/bin/vsctl"
let STATUS_PATH = "/var/run/vpnselectivo/status.json"
let EVENTS_PATH = "/var/run/vpnselectivo/events.log"
let LOG_PATH = "/Library/Logs/VPNSelectivo.log"
let README_PATH = "/Library/VPNSelectivo/share/help.html"
let RELAYS_PATH = "/Library/VPNSelectivo/etc/relays.tsv"

// Servidor de la lista pública de Mullvad (la escribe y valida vsctl).
struct Relay {
    let host: String, loc: String, country: String, city: String, active: Bool
    var cc: String { String(loc.prefix(2)) }
}

func loadRelays() -> [Relay] {
    guard let text = try? String(contentsOfFile: RELAYS_PATH, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 9 else { return nil }
        return Relay(host: f[0], loc: f[1], country: f[2], city: f[3], active: f[4] == "1")
    }
}

func flag(_ cc: String) -> String {
    String(String.UnicodeScalarView(cc.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
}
let APPS_CONF = "/Library/VPNSelectivo/etc/apps.conf"
let VSCTL_PATH = "/Library/VPNSelectivo/bin/vsctl"

// Una línea de apps.conf: id | Nombre | /Applications/App.app | argumentos
struct AppEntry {
    let id: String, name: String, path: String, args: [String], auto: Bool
    var bundleID: String? { Bundle(path: path)?.bundleIdentifier }
}

func loadApps() -> [AppEntry] {
    guard let text = try? String(contentsOfFile: APPS_CONF, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { raw in
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 3, !f[0].isEmpty, !f[1].isEmpty, f[2].hasSuffix(".app") else { return nil }
        let args = f.count > 3 ? f[3].split(separator: " ").map(String.init) : []
        let auto = f.count > 4 ? f[4] != "0" : true
        return AppEntry(id: f[0], name: f[1], path: f[2], args: args, auto: auto)
    }
}

// Ejecuta vsctl como root tras pedir la contraseña de administrador (para
// agregar/quitar apps e importar configuraciones). Solo en el hilo principal.
func runVsctlAsAdmin(_ args: [String], prompt: String) -> (ok: Bool, out: String) {
    func q(_ s: String) -> String {
        "quoted form of \"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let cmd = ([VSCTL_PATH] + args).map(q).joined(separator: " & \" \" & ")
    let script = "do shell script \(cmd) with administrator privileges with prompt \"\(prompt)\""
    var err: NSDictionary?
    if let r = NSAppleScript(source: script)?.executeAndReturnError(&err) { return (true, r.stringValue ?? "") }
    return (false, (err?[NSAppleScript.errorMessage] as? String) ?? "Cancelado")
}

struct Status: Codable {
    var ts: Int
    var configured: Bool
    var tunnel: String
    var mode: String
    var server: String
    var selected: String
    var handshake_age: Int
    var rx: Int64
    var tx: Int64
    var protected: Int
    var running: String
    var manual_down: Bool
    var pf: String
    var official_mullvad: String
    var error: String
    var enforce: Int
    var gid: Int
    var manual_on: Bool?
    var auto_vpn: Int?
    var exit_ip: String?
    var exit_country: String?
    var exit_city: String?
}

// ── información de procesos (sin privilegios) ──────────────────────────────
func procRealGID(_ pid: pid_t) -> gid_t? {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
    return kp.kp_eproc.e_pcred.p_rgid
}

func procArgs(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }   // ruta del ejecutable
    while i < size && buf[i] == 0 { i += 1 }
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

func vpnGroupID() -> gid_t? {
    guard let g = getgrnam("vpnselectivo") else { return nil }
    return g.pointee.gr_gid
}

// ── ejecución de vsctl ─────────────────────────────────────────────────────
@discardableResult
func runVsctl(_ args: [String]) -> (ok: Bool, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["-n", VSCTL] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (false, "No se pudo ejecutar vsctl: \(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
}

func humanBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .binary
    return f.string(fromByteCount: b)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var status: Status?
    var statusFresh = false
    var timer: Timer?
    var appsObservation: NSKeyValueObservation?
    var knownPIDs = Set<pid_t>()
    var eventsOffset: UInt64 = 0
    var relaunching = Set<String>()
    var lastLaunch: [String: Date] = [:]
    var lastNotifiedState = ""
    var relays: [Relay] = []
    var apps: [AppEntry] = []
    let started = Date()
    let work = DispatchQueue(label: "vpnselectivo.work")
    let model = ControlModel()
    lazy var controlWindow = ControlWindowController(model: model)

    @objc func showControl() { model.rescan(); controlWindow.show() }

    // Clic en el ícono del Dock: abrir la ventana de control.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControl(); return true
    }
    // Cerrar la ventana no cierra la app (sigue la vigilancia y el escudo).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ n: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: EVENTS_PATH),
           let size = attrs[.size] as? NSNumber {
            eventsOffset = size.uint64Value   // solo eventos nuevos
        }
        statusItem.button?.imagePosition = .imageLeft
        relays = loadRelays()
        apps = loadApps()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        model.delegate = self
        refresh()
        // Al iniciar sesión (LaunchAgent con --background) solo el Dock y el escudo.
        if !CommandLine.arguments.contains("--background") { showControl() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        // Vigilancia inmediata de lanzamientos (además del barrido de 1 s).
        appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.scanRunningApps() }
        }
        scanRunningApps()
    }

    // ── estado ────────────────────────────────────────────────────────────
    var appsStamp: Date?
    // apps.conf puede cambiar (agregar/quitar apps): recargar al instante.
    func reloadAppsIfChanged() {
        let m = (try? FileManager.default.attributesOfItem(atPath: APPS_CONF))?[.modificationDate] as? Date
        if m != appsStamp { appsStamp = m; apps = loadApps(); knownPIDs.removeAll() }
    }

    func refresh() {
        reloadAppsIfChanged()
        if let data = FileManager.default.contents(atPath: STATUS_PATH),
           let s = try? JSONDecoder().decode(Status.self, from: data) {
            status = s
            statusFresh = Int(Date().timeIntervalSince1970) - s.ts < 6
        } else {
            status = nil; statusFresh = false
        }
        updateIcon()
        readEvents()
        scanRunningApps()
        // Modelo de la ventana de control
        if model.fresh != statusFresh { model.fresh = statusFresh }
        if let s = status, let d = try? JSONEncoder().encode(s), let old = model.status,
           let d2 = try? JSONEncoder().encode(old), d == d2 {} else { model.status = status }
        if model.apps.map({ "\($0.id)\($0.auto)" }) != apps.map({ "\($0.id)\($0.auto)" }) { model.apps = apps }
        if model.relays.count != relays.count { model.relays = relays }
        model.updateRunStates()
    }

    enum Look { case protected, connecting, blocked, idle, alert, missing }

    func look() -> (Look, String) {
        guard let s = status, statusFresh else {
            return (.missing, "El servicio de VPN Selectivo no responde")
        }
        if s.pf == "broken" { return (.alert, "Cortafuegos alterado: apps protegidas congeladas") }
        if !s.configured { return (.alert, "Falta importar la configuración de Mullvad") }
        let apps = s.protected
        switch s.tunnel {
        case "up": return (.protected, "Protegido · \(describe(s.server))")
        case "stale": return (.connecting, "Sin respuesta del servidor \(s.server): tráfico protegido detenido")
        default:
            if s.manual_down { return (apps > 0 ? .blocked : .idle,
                                       apps > 0 ? "Desconectado: apps protegidas SIN Internet (bloqueadas)" : "Desconectado") }
            if apps > 0 { return (.blocked, "Conectando… (apps protegidas bloqueadas hasta conectar)") }
            return (.idle, "Inactivo · se conecta al abrir una app protegida")
        }
    }

    func updateIcon() {
        let (l, text) = look()
        let symbol: String
        switch l {
        case .protected: symbol = "lock.shield.fill"
        case .connecting: symbol = "shield.lefthalf.filled"
        case .blocked: symbol = "xmark.shield.fill"
        case .idle: symbol = "shield"
        case .alert: symbol = "exclamationmark.shield.fill"
        case .missing: symbol = "exclamationmark.triangle"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "VPN Selectivo")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = "VPN Selectivo — \(text)"
        let key = "\(l)"
        if key != lastNotifiedState {
            if lastNotifiedState != "" && (l == .blocked || l == .alert || l == .missing) && (status?.protected ?? 0) > 0 {
                notify(text)
            }
            lastNotifiedState = key
        }
    }

    // ── menú ──────────────────────────────────────────────────────────────
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let (_, text) = look()
        let head = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(item("Abrir panel de control…", #selector(showControl)))
        if let s = status, statusFresh {
            let open = s.running.split(separator: ",").compactMap { id in apps.first { $0.id == id }?.name }
            var detail = open.isEmpty ? "Ninguna app protegida abierta" : "Abiertas: " + open.joined(separator: ", ")
            if s.tunnel == "up" || s.tunnel == "stale" {
                detail += " · handshake hace \(s.handshake_age) s · ↓\(humanBytes(s.rx)) ↑\(humanBytes(s.tx))"
            }
            let d = NSMenuItem(title: detail, action: nil, keyEquivalent: ""); d.isEnabled = false
            menu.addItem(d)
            if s.official_mullvad == "Connected" || s.official_mullvad == "Connecting" {
                let w = NSMenuItem(title: "⚠︎ El cliente oficial de Mullvad está conectado (todo el Mac va por VPN)", action: nil, keyEquivalent: "")
                w.isEnabled = false
                menu.addItem(w)
            }
            if !s.error.isEmpty && s.tunnel != "up" {
                let e = NSMenuItem(title: "Último error: \(errorText(s.error))", action: nil, keyEquivalent: ""); e.isEnabled = false
                menu.addItem(e)
            }
        }
        menu.addItem(.separator())
        apps = loadApps()
        if apps.isEmpty {
            let e = NSMenuItem(title: "No hay apps protegidas: agrega una abajo", action: nil, keyEquivalent: ""); e.isEnabled = false
            menu.addItem(e)
        }
        for a in apps {
            let it = item("Abrir \(a.name) (VPN)", #selector(openApp(_:)))
            it.representedObject = a.id
            if let icon = Bundle(path: a.path).map({ NSWorkspace.shared.icon(forFile: $0.bundlePath) }) {
                icon.size = NSSize(width: 16, height: 16); it.image = icon
            }
            menu.addItem(it)
        }
        let manage = NSMenuItem(title: "Apps protegidas", action: nil, keyEquivalent: "")
        let mm = NSMenu()
        mm.addItem(item("Agregar app protegida…", #selector(addApp)))
        let rem = NSMenuItem(title: "Quitar app protegida", action: nil, keyEquivalent: "")
        let rm = NSMenu()
        for a in apps {
            let it = item("\(a.name)\(a.args.isEmpty ? "" : " (" + a.args.joined(separator: " ") + ")")", #selector(removeApp(_:)))
            it.representedObject = a.id
            rm.addItem(it)
        }
        if apps.isEmpty { let e = NSMenuItem(title: "(ninguna)", action: nil, keyEquivalent: ""); e.isEnabled = false; rm.addItem(e) }
        rem.submenu = rm
        mm.addItem(rem)
        manage.submenu = mm
        menu.addItem(manage)
        menu.addItem(.separator())
        menu.addItem(item("Comprobar IP de salida…", #selector(checkIP)))
        if let s = status, s.tunnel == "up" {
            menu.addItem(item("Desconectar VPN (las apps protegidas quedan sin Internet)", #selector(disconnect)))
        } else {
            menu.addItem(item("Conectar VPN", #selector(connect)))
        }
        relays = loadRelays()
        menu.addItem(locationItem())
        menu.addItem(item("Importar configuración WireGuard de Mullvad…", #selector(importConfig)))
        menu.addItem(.separator())
        menu.addItem(item("Autodiagnóstico de fugas…", #selector(selftest)))
        menu.addItem(item("Vigilar fugas 60 s (con apps abiertas)…", #selector(leakwatch)))
        menu.addItem(item("Abrir registro", #selector(openLog)))
        menu.addItem(item("Ayuda", #selector(openHelp)))
        menu.addItem(.separator())
        menu.addItem(item("Salir de la app de menú (la protección sigue activa)", #selector(quit)))
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func errorText(_ code: String) -> String {
        switch code {
        case "no_config": return "no hay configuración de Mullvad importada"
        case "bad_config": return "configuración de servidor inválida"
        case "handshake_failed": return "el servidor no respondió (¿sin Internet o clave revocada?)"
        case "wg_start_failed", "wg_config_failed": return "no se pudo iniciar WireGuard"
        case "missing_binaries": return "faltan componentes; reinstala"
        case "pf_failed": return "no se pudieron cargar las reglas del cortafuegos"
        case "no_server": return "no hay servidores activos en la ubicación elegida"
        default: return code
        }
    }

    // ── acciones ──────────────────────────────────────────────────────────
    func launch(_ app: String, restore: Bool = false) {
        lastLaunch[app] = Date()
        work.async {
            var args = ["launch", app]
            if restore { args.append("--restore") }
            let r = runVsctl(args)
            if !r.ok {
                DispatchQueue.main.async { self.alert("No se pudo abrir \(app)", r.out) }
            }
        }
    }
    @objc func openApp(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { launch(id) }
    }

    // ── agregar / quitar apps protegidas (piden contraseña de administrador) ──
    @objc func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Elige la app que debe usar siempre la VPN"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else {
            alert("Ubicación no admitida", "La app debe estar en /Applications o en ~/Applications."); return
        }
        let bundle = Bundle(path: path)
        var name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        name = String(name.filter { !"\"'\\$`/|<>;&".contains($0) }.prefix(40))
        let id = appSlug(name, taken: apps.map { $0.id })
        let a = NSAlert()
        a.messageText = "¿Proteger \(name)?"
        a.informativeText = "\(name) usará siempre Mullvad: si la VPN cae, se queda sin Internet. Si la abres por fuera (Dock, Spotlight), se cerrará y se reabrirá protegida.\n\nFunciona con apps que hacen su propia conexión (navegadores Chromium/Firefox, apps Electron, clientes torrent). Las apps de Apple que usan servicios del sistema (Safari, Mail…) no quedan cubiertas."
        a.addButton(withTitle: "Proteger"); a.addButton(withTitle: "Cancelar")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let r = runVsctlAsAdmin(["app-add", id, name, path], prompt: "VPN Selectivo: proteger \(name)")
        apps = loadApps()
        alert(r.ok ? "App protegida" : "No se pudo agregar", r.out)
    }

    @objc func removeApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let e = apps.first(where: { $0.id == id }) else { return }
        let a = NSAlert()
        a.messageText = "¿Dejar de proteger \(e.name)?"
        a.informativeText = "Volverá a usar tu conexión normal la próxima vez que la abras. Si está abierta ahora, sigue protegida hasta que la cierres."
        a.addButton(withTitle: "Quitar"); a.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let r = runVsctlAsAdmin(["app-remove", id], prompt: "VPN Selectivo: dejar de proteger \(e.name)")
        apps = loadApps()
        if !r.ok { alert("No se pudo quitar", r.out) } else { notify(r.out) }
    }

    @objc func connect() { work.async { let r = runVsctl(["connect"]); if !r.ok { DispatchQueue.main.async { self.alert("No se pudo conectar", r.out) } } } }

    @objc func disconnect() {
        let a = NSAlert()
        a.messageText = "¿Desconectar la VPN?"
        a.informativeText = "Las apps protegidas NO se cerrarán: quedarán abiertas pero sin Internet (bloqueadas) hasta que vuelvas a conectar o abras una app protegida. Chrome y el resto del Mac no se ven afectados."
        a.addButton(withTitle: "Desconectar"); a.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { work.async { runVsctl(["disconnect"]) } }
    }

    // ── ubicación ─────────────────────────────────────────────────────────
    // "se" → Sweden (automático); "us-nyc" → USA, New York (automático);
    // "us-nyc-wg-301" → servidor concreto.
    func describe(_ code: String) -> String {
        if let r = relays.first(where: { $0.host == code }) { return "\(flag(r.cc)) \(r.country), \(r.city) · \(r.host)" }
        if let r = relays.first(where: { $0.loc == code }) { return "\(flag(r.cc)) \(r.country), \(r.city) (automático)" }
        if let r = relays.first(where: { $0.cc == code }) { return "\(flag(r.cc)) \(r.country) (automático)" }
        return code
    }

    func choice(_ title: String, _ code: String, _ sel: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(selectLocation(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = code
        it.state = sel == code ? .on : .off
        return it
    }

    func locationItem() -> NSMenuItem {
        let sel = status?.selected ?? ""
        let top = NSMenuItem(title: "Ubicación: \(describe(sel))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if relays.isEmpty {
            // Sin lista pública todavía: solo las configuraciones importadas.
            for line in runVsctl(["servers"]).out.split(separator: "\n").map(String.init) where line.count > 2 {
                let name = String(line.dropFirst(2))
                sub.addItem(choice(name, name, line.hasPrefix("*") ? name : sel))
            }
            sub.addItem(.separator())
            sub.addItem(item("Descargar la lista de servidores de Mullvad", #selector(updateRelays)))
            top.submenu = sub
            return top
        }
        let inSel = { (code: String) -> Bool in sel == code || sel.hasPrefix(code + "-") }
        let countries = Dictionary(grouping: relays, by: { $0.cc }).sorted { $0.value[0].country < $1.value[0].country }
        for (cc, rs) in countries {
            let active = rs.filter { $0.active }.count
            let cItem = NSMenuItem(title: "\(flag(cc))  \(rs[0].country)", action: nil, keyEquivalent: "")
            cItem.state = inSel(cc) ? .on : .off
            cItem.isEnabled = active > 0
            let cMenu = NSMenu()
            cMenu.autoenablesItems = false
            cMenu.addItem(choice("Cualquier ciudad (automático)", cc, sel))
            cMenu.addItem(.separator())
            let cities = Dictionary(grouping: rs, by: { $0.loc }).sorted { $0.value[0].city < $1.value[0].city }
            for (loc, crs) in cities {
                let cityItem = NSMenuItem(title: crs[0].city, action: nil, keyEquivalent: "")
                cityItem.state = inSel(loc) ? .on : .off
                cityItem.isEnabled = crs.contains { $0.active }
                let m = NSMenu()
                m.autoenablesItems = false
                m.addItem(choice("Automático (\(crs.filter { $0.active }.count) servidores)", loc, sel))
                m.addItem(.separator())
                for r in crs.sorted(by: { $0.host < $1.host }) {
                    let it = choice(r.active ? r.host : "\(r.host) (fuera de servicio)", r.host, sel)
                    it.isEnabled = r.active
                    m.addItem(it)
                }
                cityItem.submenu = m
                cMenu.addItem(cityItem)
            }
            cItem.submenu = cMenu
            sub.addItem(cItem)
        }
        sub.addItem(.separator())
        sub.addItem(item("Actualizar lista de servidores", #selector(updateRelays)))
        top.submenu = sub
        return top
    }

    @objc func selectLocation(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        let name = describe(code)
        notify("Cambiando a \(name)… Las apps protegidas quedan sin Internet unos segundos mientras reconecta.")
        work.async {
            let r = runVsctl(["select", code])
            DispatchQueue.main.async {
                if r.ok { self.notify(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) }
                else { self.alert("No se pudo cambiar de ubicación", r.out) }
            }
        }
    }

    @objc func updateRelays() {
        work.async {
            let r = runVsctl(["relays", "update"])
            DispatchQueue.main.async {
                self.relays = loadRelays()
                if r.ok { self.notify(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) }
                else { self.alert("No se pudo actualizar la lista", r.out) }
            }
        }
    }


    @objc func importConfig() {
        let panel = NSOpenPanel()
        panel.title = "Configuración WireGuard de Mullvad (.conf o .zip)"
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .data, .zip]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Importar exige contraseña de administrador (no está en la regla sudoers).
        let r = runVsctlAsAdmin(["import", url.path], prompt: "VPN Selectivo: importar configuración de Mullvad")
        alert(r.ok ? "Configuración importada" : "No se pudo importar", r.out)
    }

    @objc func checkIP() {
        work.async {
            let r = runVsctl(["check-ip"])
            DispatchQueue.main.async { self.alert("IP de salida", r.out, mono: true) }
        }
    }
    @objc func selftest() {
        notify("Ejecutando autodiagnóstico (unos 30 s; incluye cortar el túnel a propósito)…")
        work.async {
            let r = runVsctl(["selftest"])
            DispatchQueue.main.async { self.alert(r.ok ? "Autodiagnóstico superado" : "Autodiagnóstico con fallos", r.out, mono: true) }
        }
    }
    @objc func leakwatch() {
        notify("Vigilando fugas durante 60 s: usa tus apps protegidas con normalidad…")
        work.async {
            let r = runVsctl(["leakwatch", "60"])
            DispatchQueue.main.async { self.alert("Vigilancia de fugas", r.out, mono: true) }
        }
    }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: LOG_PATH)) }
    @objc func openHelp() { NSWorkspace.shared.open(URL(fileURLWithPath: README_PATH)) }
    @objc func quit() { NSApp.terminate(nil) }

    // ── lanzamientos por fuera de la VPN ─────────────────────────────────
    func scanRunningApps() {
        guard let s = status, statusFresh, s.enforce == 1, let gid = vpnGroupID() else { return }
        if apps.isEmpty { apps = loadApps() }
        var byBundle: [String: [AppEntry]] = [:]
        for e in apps { if let b = e.bundleID { byBundle[b, default: []].append(e) } }
        var current = Set<pid_t>()
        let graced = Set(((try? String(contentsOfFile: GRACE_PATH, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { pid_t($0) })
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, let entries = byBundle[bid] else { continue }
            let pid = app.processIdentifier
            current.insert(pid)
            if knownPIDs.contains(pid) { continue }
            // Abierta antes de marcarla y el usuario eligió «Al cerrarla»: no tocar.
            if graced.contains(pid) { continue }
            guard let rgid = procRealGID(pid) else { continue }
            if rgid == gid { continue }
            // Fuera del grupo: no puede usar el túnel. Terminar ya y reabrir con
            // la entrada cuyos argumentos coinciden (p. ej. --incognito).
            let pargs = procArgs(pid)
            let target = entries.first { !$0.args.isEmpty && $0.args.allSatisfy(pargs.contains) }
                ?? entries.first { $0.args.isEmpty } ?? entries[0]
            kill(pid, SIGKILL)
            relaunchProtected(target.id, waitingFor: pid, message: "\(target.name) se abrió sin VPN: se cerró al instante y se reabre protegida.")
        }
        knownPIDs = current
    }

    func relaunchProtected(_ target: String, waitingFor pid: pid_t?, message: String) {
        // Una relanzada a la vez por app (varias entradas pueden compartir app).
        let key = apps.first { $0.id == target }?.path ?? target
        if relaunching.contains(key) { return }
        if let t = lastLaunch[target], Date().timeIntervalSince(t) < 5 { return }
        relaunching.insert(key)
        notify(message)
        work.async {
            if let pid = pid {
                for _ in 0..<40 where kill(pid, 0) == 0 { usleep(50_000) }
            }
            usleep(300_000)
            let r = runVsctl(["launch", target, "--restore"])
            DispatchQueue.main.async {
                self.lastLaunch[target] = Date()
                self.relaunching.remove(key)
                if !r.ok { self.alert("No se pudo reabrir protegida", r.out) }
            }
        }
    }

    // Eventos del daemon: procesos que él mismo terminó (p. ej. sin esta app).
    func readEvents() {
        guard let fh = FileHandle(forReadingAtPath: EVENTS_PATH) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < eventsOffset { eventsOffset = 0 }   // el daemon truncó el archivo
        if size == eventsOffset { return }
        try? fh.seek(toOffset: eventsOffset)
        let data = fh.readDataToEndOfFile()
        eventsOffset = size
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 3, let ts = Double(f[0]), ts >= started.timeIntervalSince1970 - 1 else { continue }
            switch (f[1], f[2]) {
            case ("stray", let target):
                guard let e = apps.first(where: { $0.id == target }), let bid = e.bundleID else { break }
                // Solo si no hay ya una instancia protegida en marcha.
                let gid = vpnGroupID()
                let protectedRunning = NSWorkspace.shared.runningApplications.contains {
                    $0.bundleIdentifier == bid && procRealGID($0.processIdentifier) == gid
                }
                if !protectedRunning {
                    relaunchProtected(target, waitingFor: nil, message: "\(e.name) se abrió sin VPN: se cerró y se reabre protegida.")
                }
            case ("tunnel_lost", _):
                notify("El túnel se cayó: las apps protegidas quedan sin Internet mientras se reconecta (no hay salida sin VPN).")
            case ("pf_repaired", _):
                notify("El cortafuegos fue alterado por otro programa y se restauró. Las apps protegidas se congelaron durante la reparación.")
            default: break
            }
        }
    }

    // ── avisos ────────────────────────────────────────────────────────────
    func notify(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "VPN Selectivo"
        c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func alert(_ title: String, _ text: String, mono: Bool = false) {
        let a = NSAlert()
        a.messageText = title
        if mono {
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
            tv.string = text
            tv.isEditable = false
            tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let sv = NSScrollView(frame: tv.frame)
            sv.documentView = tv
            sv.hasVerticalScroller = true
            a.accessoryView = sv
        } else {
            a.informativeText = text
        }
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

