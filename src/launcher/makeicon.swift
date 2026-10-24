// Genera un .icns a partir del icono de una app, con una insignia de escudo
// (para distinguir en el Dock "Brave VPN" de "Brave"). Sin argumento de
// origen, dibuja el icono de la app de menú.
// uso: makeicon <origen.icns|-> <salida.icns> <hex-color-insignia>
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else { fputs("uso: makeicon <origen|-> <salida.icns> <color>\n", stderr); exit(64) }
let src = args[1], out = args[2]
let hex = UInt32(args[3], radix: 16) ?? 0x1F8A4C
let color = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let full = NSRect(x: 0, y: 0, width: s, height: s)
    if src != "-", let base = NSImage(contentsOfFile: src) {
        base.draw(in: full)
        // insignia: círculo de color con escudo blanco, abajo a la derecha
        let d = s * 0.46
        let r = NSRect(x: s - d - s * 0.02, y: s * 0.02, width: d, height: d)
        NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: -s * 0.015, dy: -s * 0.015)).fill()
        color.setFill(); NSBezierPath(ovalIn: r).fill()
        drawSymbol("lock.shield.fill", in: r.insetBy(dx: d * 0.2, dy: d * 0.2))
    } else {
        let bg = NSBezierPath(roundedRect: full.insetBy(dx: s * 0.1, dy: s * 0.1), xRadius: s * 0.18, yRadius: s * 0.18)
        NSGradient(starting: color, ending: color.blended(withFraction: 0.45, of: .black)!)!.draw(in: bg, angle: -90)
        drawSymbol("lock.shield.fill", in: full.insetBy(dx: s * 0.26, dy: s * 0.26))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawSymbol(_ name: String, in rect: NSRect) {
    let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    let ratio = min(rect.width / sym.size.width, rect.height / sym.size.height)
    let w = sym.size.width * ratio, h = sym.size.height * ratio
    sym.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vsicon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
exit(p.terminationStatus)
