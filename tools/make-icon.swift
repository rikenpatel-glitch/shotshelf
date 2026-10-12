// Renders the app icon: swift tools/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824pt rounded square centered in 1024
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let colors = [NSColor(red: 0.42, green: 0.36, blue: 1.0, alpha: 1).cgColor,
                  NSColor(red: 0.13, green: 0.75, blue: 0.93, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.fillEllipse(in: CGRect(x: 80 * s, y: 560 * s, width: 700 * s, height: 520 * s))
    ctx.restoreGState()

    // Three stacked screenshots
    func card(_ rect: CGRect, _ angle: CGFloat, _ alpha: CGFloat, content: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: angle * .pi / 180)
        let r = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        let p = CGPath(roundedRect: r, cornerWidth: 34 * s, cornerHeight: 34 * s, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.addPath(p); ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        if content {
            let bar = CGRect(x: r.minX, y: r.maxY - 62 * s, width: r.width, height: 62 * s)
            ctx.saveGState(); ctx.addPath(p); ctx.clip()
            ctx.setFillColor(NSColor(red: 0.90, green: 0.91, blue: 0.97, alpha: 1).cgColor); ctx.fill(bar)
            ctx.restoreGState()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                ctx.setFillColor(c.cgColor)
                ctx.fillEllipse(in: CGRect(x: r.minX + (34 + CGFloat(i) * 38) * s, y: bar.midY - 11 * s, width: 22 * s, height: 22 * s))
            }
            ctx.setFillColor(NSColor(red: 0.42, green: 0.36, blue: 1.0, alpha: 0.9).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + 40 * s, y: r.minY + 150 * s, width: r.width * 0.42, height: 120 * s), cornerWidth: 18 * s, cornerHeight: 18 * s, transform: nil)); ctx.fillPath()
            ctx.setFillColor(NSColor(red: 0.80, green: 0.82, blue: 0.92, alpha: 1).cgColor)
            for row in 0..<3 {
                let w: CGFloat = [0.38, 0.30, 0.34][row]
                ctx.addPath(CGPath(roundedRect: CGRect(x: r.midX + 10 * s, y: r.minY + (240 - CGFloat(row) * 46) * s, width: r.width * w, height: 24 * s), cornerWidth: 12 * s, cornerHeight: 12 * s, transform: nil)); ctx.fillPath()
            }
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + 40 * s, y: r.minY + 60 * s, width: r.width - 80 * s, height: 50 * s), cornerWidth: 14 * s, cornerHeight: 14 * s, transform: nil)); ctx.fillPath()
        }
        ctx.restoreGState()
    }
    card(CGRect(x: 250 * s, y: 330 * s, width: 560 * s, height: 400 * s), 12, 0.45, content: false)
    card(CGRect(x: 230 * s, y: 300 * s, width: 560 * s, height: 400 * s), 5, 0.7, content: false)
    card(CGRect(x: 212 * s, y: 262 * s, width: 600 * s, height: 430 * s), -4, 1, content: true)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(px).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/icon-preview.png"))
print("Wrote \(dir.path)")
