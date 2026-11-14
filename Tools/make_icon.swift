// Generates Coast.icns from the same SF Symbol used in the menu bar (cursorarrow.motionlines),
// rendered white on a dark rounded tile. Renders a 1024 px master with AppKit, downscales the
// iconset sizes with `sips`, and packs them with `iconutil`.
// Usage: make_icon <output-dir>   (writes <output-dir>/Coast.icns)
import AppKit

let symbolName = "cursorarrow.motionlines"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath

func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { fatalError("\(tool) failed") }
}

/// A white-filled copy of a (template) SF Symbol image.
func tintedWhite(_ symbol: NSImage) -> NSImage {
    let rect = NSRect(origin: .zero, size: symbol.size)
    let out = NSImage(size: symbol.size)
    out.lockFocus()
    symbol.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func renderMaster(px: Int) -> URL {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(px)

    // Rounded tile with a ~10% margin (matches the visual weight of other icons).
    let margin = size * 0.10, tile = size - 2 * margin, radius = tile * 0.2237
    let path = NSBezierPath(roundedRect: NSRect(x: margin, y: margin, width: tile, height: tile), xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor(srgbRed: 0.27, green: 0.27, blue: 0.30, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))!.draw(in: path, angle: -90)

    // White motion-cursor glyph, centred, ~52% of the canvas.
    var sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!
    sym = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.40, weight: .regular)) ?? sym
    sym = tintedWhite(sym)
    let gs = sym.size
    let scale = (size * 0.52) / max(gs.width, gs.height)
    let gw = gs.width * scale, gh = gs.height * scale
    sym.draw(in: NSRect(x: (size - gw) / 2, y: (size - gh) / 2, width: gw, height: gh),
             from: NSRect(origin: .zero, size: gs), operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("Coast_master.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

let master = renderMaster(px: 1024)
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("Coast.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in specs {
    run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path])
}
let icns = URL(fileURLWithPath: outDir).appendingPathComponent("Coast.icns")
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.removeItem(at: master)
print("wrote \(icns.path)")
