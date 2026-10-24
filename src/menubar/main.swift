// VPN Selectivo — punto de entrada: app normal (ícono en el Dock y ventana de
// control) más el escudo de la barra de menús.
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
