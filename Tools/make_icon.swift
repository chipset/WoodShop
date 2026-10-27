// Draws the WoodShop app icon and writes Resources/AppIcon.icns.  Run: swift Tools/make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    // Background tile
    let tile = CGRect(x: 60, y: 60, width: 904, height: 904)
    let path = CGPath(roundedRect: tile, cornerWidth: 200, cornerHeight: 200, transform: nil)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(deviceRed: 0.20, green: 0.34, blue: 0.52, alpha: 1).cgColor,
                                   NSColor(deviceRed: 0.10, green: 0.18, blue: 0.30, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()
    // An isometric board with a dado: top, left and right faces.
    func poly(_ pts: [CGPoint], _ color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.beginPath(); ctx.addLines(between: pts); ctx.closePath(); ctx.fillPath()
    }
    func iso(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: 512 + (x - z) * 0.866 * 170, y: 600 - (x + z) * 0.5 * 170 + y * 170)
    }
    let L: CGFloat = 3.0, W: CGFloat = 1.6, T: CGFloat = 0.8
    let top = NSColor(deviceRed: 0.93, green: 0.76, blue: 0.50, alpha: 1)
    let left = NSColor(deviceRed: 0.74, green: 0.55, blue: 0.32, alpha: 1)
    let right = NSColor(deviceRed: 0.60, green: 0.42, blue: 0.24, alpha: 1)
    let ox: CGFloat = -1.5, oz: CGFloat = -0.8
    func P(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint { iso(x + ox, y, z + oz) }
    // faces (x along length, z along width, y up)
    poly([P(0, T, 0), P(L, T, 0), P(L, T, W), P(0, T, W)], top)
    poly([P(0, 0, W), P(L, 0, W), P(L, T, W), P(0, T, W)], left)
    poly([P(L, 0, 0), P(L, 0, W), P(L, T, W), P(L, T, 0)], right)
    // dado groove across the top
    let g0: CGFloat = 1.1, g1: CGFloat = 1.7, d: CGFloat = 0.4
    poly([P(g0, T, 0), P(g1, T, 0), P(g1, T, W), P(g0, T, W)], NSColor(deviceRed: 0.45, green: 0.31, blue: 0.17, alpha: 1))
    poly([P(g0, T - d, W), P(g1, T - d, W), P(g1, T, W), P(g0, T, W)], NSColor(deviceRed: 0.55, green: 0.38, blue: 0.21, alpha: 1))
    // grain lines on the top
    ctx.setStrokeColor(NSColor(deviceRed: 0.70, green: 0.50, blue: 0.28, alpha: 0.6).cgColor)
    ctx.setLineWidth(5)
    for z in stride(from: CGFloat(0.25), to: W, by: 0.3) {
        for (a, b) in [(CGFloat(0.05), g0 - 0.05), (g1 + 0.05, L - 0.05)] {
            ctx.move(to: P(a, T, z)); ctx.addLine(to: P(b, T, z)); ctx.strokePath()
        }
    }
    // dimension line
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(10)
    let a = P(0, 0, W + 0.35), b = P(L, 0, W + 0.35)
    ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    for p in [a, b] {
        ctx.move(to: CGPoint(x: p.x - 18, y: p.y + 22)); ctx.addLine(to: CGPoint(x: p.x + 18, y: p.y - 22)); ctx.strokePath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let set = root.appendingPathComponent("Resources/AppIcon.iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try? fm.removeItem(at: set)
print("Wrote Resources/AppIcon.icns")
