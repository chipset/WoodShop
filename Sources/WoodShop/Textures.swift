import AppKit

struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Procedural, tileable wood-grain textures; grain runs along the horizontal (u) axis.
enum WoodTexture {
    private static var cache: [Species: NSImage] = [:]
    private static let lock = NSLock()

    static func image(for s: Species) -> NSImage {
        lock.lock()
        let cached = cache[s]
        lock.unlock()
        if let cached { return cached }
        let img = make(s)
        lock.lock()
        if let cached = cache[s] { lock.unlock(); return cached }
        cache[s] = img
        lock.unlock()
        return img
    }

    static func prewarm(_ species: Set<Species>) {
        for material in species { _ = image(for:material) }
    }

    private static func make(_ s: Species) -> NSImage {
        let W = 512, H = 512
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage() }
        let base = s.base
        ctx.setFillColor(base.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        var rng = LCG(state: UInt64(s.rawValue.utf8.reduce(7) { ($0 &* 31) &+ Int($1) }))
        func r(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &rng) }

        let lines: Int
        switch s {
        case .mdf: lines = 0
        case .plywood: lines = 70
        case .pine: lines = 100
        default: lines = 150
        }
        for _ in 0..<lines {
            let y0 = r(0, Double(H)), amp = r(2, s == .oak || s == .pine ? 16 : 9)
            let k = Double(Int.random(in: 1...3, using: &rng)), phase = r(0, 6.28)
            let f = r(0.55, 0.85)
            ctx.setStrokeColor(NSColor(deviceRed: base.redComponent * f, green: base.greenComponent * f,
                                       blue: base.blueComponent * f, alpha: r(0.05, 0.22)).cgColor)
            ctx.setLineWidth(r(0.6, 3))
            for off in [-Double(H), 0, Double(H)] {
                ctx.beginPath()
                for x in stride(from: 0, through: W, by: 8) {
                    let y = y0 + off + amp * sin(2 * .pi * k * Double(x) / Double(W) + phase)
                    x == 0 ? ctx.move(to: CGPoint(x: Double(x), y: y)) : ctx.addLine(to: CGPoint(x: Double(x), y: y))
                }
                ctx.strokePath()
            }
        }
        // Fine speckle so flat colours don't look plastic.
        for _ in 0..<(s == .mdf ? 9000 : 2500) {
            let f = r(0.8, 1.15)
            ctx.setFillColor(NSColor(deviceRed: min(1, base.redComponent * f), green: min(1, base.greenComponent * f),
                                     blue: min(1, base.blueComponent * f), alpha: 0.25).cgColor)
            ctx.fill(CGRect(x: r(0, Double(W)), y: r(0, Double(H)), width: r(1, 3), height: 1))
        }
        guard let cg = ctx.makeImage() else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: W, height: H))
    }
}
