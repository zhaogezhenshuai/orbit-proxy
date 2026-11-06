import AppKit
import SwiftUI

/// Whether a flag emoji actually draws on this Mac. Some flags are suppressed by region (🇹🇼 on
/// China-region systems draws as a grey box), so each one is drawn once off-screen and kept only
/// if it comes out in colour.
@MainActor
enum FlagCheck {
    private static var cache: [String: Bool] = [:]

    static func renders(_ flag: String) -> Bool {
        if let r = cache[flag] { return r }
        let r = drawsInColour(flag)
        cache[flag] = r
        return r
    }

    private static func drawsInColour(_ s: String) -> Bool {
        let size = 20
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return true }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (s as NSString).draw(at: .zero, withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.restoreGraphicsState()
        for x in 0..<size {
            for y in 0..<size {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
                let lo = min(c.redComponent, c.greenComponent, c.blueComponent)
                if hi - lo > 0.2 { return true }
            }
        }
        return false
    }

    /// "🇹🇼" → "TW".
    static func code(_ flag: String) -> String {
        String(flag.unicodeScalars.compactMap { s in
            (0x1F1E6...0x1F1FF).contains(s.value) ? Character(UnicodeScalar(s.value - 0x1F1E6 + 65)!) : nil
        })
    }
}

/// A flag emoji, or its two-letter region code in a small badge where the emoji can't be drawn.
/// An empty flag shows 🌐.
struct FlagIcon: View {
    let flag: String
    var size: CGFloat = 13

    var body: some View {
        if flag.isEmpty {
            Text("🌐").font(.system(size: size))
        } else if FlagCheck.renders(flag) {
            Text(flag).font(.system(size: size))
        } else {
            Text(FlagCheck.code(flag))
                .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: size * 1.35, height: size * 0.95)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
        }
    }
}
