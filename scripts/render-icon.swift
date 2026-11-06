// Draws Orbit's app icon (a paper plane on a blue-purple squircle) and writes Resources/AppIcon.icns.
// Every shape is drawn here; no SF Symbols, whose license doesn't allow them in app icons.
// Usage: swift scripts/render-icon.swift   (run from the repo root)
import AppKit

let size = 1024.0

func renderPNG(to url: URL) throws {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSGradient(colors: [NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.95, alpha: 1),
                            NSColor(calibratedRed: 0.45, green: 0.2, blue: 0.85, alpha: 1)])!.draw(in: tile, angle: -60)

        // Plane in unit coordinates inside the tile (origin bottom-left), pointing up-right.
        func p(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: 100 + x * 824, y: 100 + y * 824) }
        let tip = p(0.80, 0.78), left = p(0.17, 0.50), fold = p(0.45, 0.42), tail = p(0.57, 0.17)
        let keel = p(0.43, 0.30)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowBlurRadius = 30
        shadow.set()
        // Upper wing.
        let upper = NSBezierPath()
        upper.move(to: tip); upper.line(to: left); upper.line(to: fold); upper.close()
        NSColor.white.setFill()
        upper.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Lower wing, slightly shaded so the fold reads.
        let lower = NSBezierPath()
        lower.move(to: tip); lower.line(to: fold); lower.line(to: tail); lower.close()
        NSColor(calibratedRed: 0.86, green: 0.88, blue: 1.0, alpha: 1).setFill()
        lower.fill()

        // Keel under the fold, darker still.
        let under = NSBezierPath()
        under.move(to: fold); under.line(to: keel); under.line(to: tail); under.close()
        NSColor(calibratedRed: 0.70, green: 0.74, blue: 0.98, alpha: 1).setFill()
        under.fill()
        return true
    }
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("orbit-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }
let master = work.appendingPathComponent("icon1024.png")
try renderPNG(to: master)

func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
}

for s in [16, 32, 128, 256, 512] {
    try run("/usr/bin/sips", ["-z", "\(s)", "\(s)", master.path, "--out", iconset.appendingPathComponent("icon_\(s)x\(s).png").path])
    try run("/usr/bin/sips", ["-z", "\(s * 2)", "\(s * 2)", master.path, "--out", iconset.appendingPathComponent("icon_\(s)x\(s)@2x.png").path])
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"])
if CommandLine.arguments.count > 1 { try fm.copyItem(at: master, to: URL(fileURLWithPath: CommandLine.arguments[1])) }
print("wrote Resources/AppIcon.icns")
