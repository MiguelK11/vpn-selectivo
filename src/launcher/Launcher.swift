// VPN Selectivo — lanzador para el Dock ("‹App› VPN", uno por cada app
// protegida; vsctl app-sync los genera). La app viene de la clave VSLaunchApp del
// Info.plist del bundle. Todo el trabajo lo hace `vsctl launch` (root, vía la
// regla sudoers limitada): comprobar PF, levantar el túnel y lanzar la app con
// el grupo protegido.
import AppKit

let target = Bundle.main.object(forInfoDictionaryKey: "VSLaunchApp") as? String ?? ""
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
p.arguments = ["-n", "/Library/VPNSelectivo/bin/vsctl", "launch", target]
let pipe = Pipe()
p.standardOutput = pipe
p.standardError = pipe
var message = ""
do {
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    message = String(decoding: data, as: UTF8.self)
} catch {
    message = error.localizedDescription
}
if p.terminationStatus != 0 || message.contains("AVISO") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let a = NSAlert()
    a.messageText = p.terminationStatus != 0 ? "VPN Selectivo no pudo abrir la app" : "VPN Selectivo"
    a.informativeText = message.isEmpty ? "Error desconocido (¿está instalado VPN Selectivo?)" : message
    a.alertStyle = p.terminationStatus != 0 ? .critical : .warning
    app.activate(ignoringOtherApps: true)
    a.runModal()
}
exit(p.terminationStatus == 0 ? 0 : 1)
