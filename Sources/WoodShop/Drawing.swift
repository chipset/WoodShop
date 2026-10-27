import AppKit
import UniformTypeIdentifiers

/// Printable shop drawings: assembly views, cut list, and a flat detail sheet per distinct board.
enum Drawing {
    private static let page = CGRect(x: 0, y: 0, width: 792, height: 612)

    // MARK: Text & dimension helpers

    private static func text(_ s: String, at p: CGPoint, size: CGFloat = 9, bold: Bool = false,
                             center: Bool = false, color: NSColor = .black) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let w = str.size().width
        str.draw(at: CGPoint(x: center ? p.x - w / 2 : p.x, y: p.y))
    }

    private static func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint) {
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    }

    /// Dimension line between a and b, pushed out by `off` (a perpendicular vector).
    private static func dim(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, off: CGPoint, _ label: String) {
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(0.5)
        let a2 = CGPoint(x: a.x + off.x, y: a.y + off.y), b2 = CGPoint(x: b.x + off.x, y: b.y + off.y)
        let ext = CGPoint(x: off.x * 1.15, y: off.y * 1.15)
        line(ctx, a, CGPoint(x: a.x + ext.x, y: a.y + ext.y))
        line(ctx, b, CGPoint(x: b.x + ext.x, y: b.y + ext.y))
        line(ctx, a2, b2)
        let d = CGPoint(x: b2.x - a2.x, y: b2.y - a2.y)
        let len = max((d.x * d.x + d.y * d.y).squareRoot(), 0.001)
        let u = CGPoint(x: d.x / len * 5, y: d.y / len * 5), n = CGPoint(x: -u.y * 0.5, y: u.x * 0.5)
        for (tip, s) in [(a2, 1.0), (b2, -1.0)] {
            line(ctx, tip, CGPoint(x: tip.x + (u.x * s) + n.x, y: tip.y + (u.y * s) + n.y))
            line(ctx, tip, CGPoint(x: tip.x + (u.x * s) - n.x, y: tip.y + (u.y * s) - n.y))
        }
        text(label, at: CGPoint(x: (a2.x + b2.x) / 2, y: (a2.y + b2.y) / 2 + (abs(d.y) < abs(d.x) ? 2 : -3)),
             size: 8, center: true, color: .systemBlue)
    }

    // MARK: Projection

    private struct ViewDef {
        let name: String
        let h: (SIMD3<Double>) -> Double
        let v: (SIMD3<Double>) -> Double
        let depth: (SIMD3<Double>) -> Double
    }

    private static let views: [String: ViewDef] = [
        "front": ViewDef(name: "FRONT", h: { $0.x }, v: { $0.y }, depth: { $0.z }),
        "top": ViewDef(name: "TOP", h: { $0.x }, v: { -$0.z }, depth: { $0.y }),
        "right": ViewDef(name: "RIGHT", h: { -$0.z }, v: { $0.y }, depth: { $0.x }),
    ]

    private static func extents(_ p: Part) -> (lo: SIMD3<Double>, hi: SIMD3<Double>) {
        var lo = SIMD3<Double>.zero, hi = p.size
        for c in p.cuts where c.additive { lo = pointwiseMin(lo, c.lo); hi = pointwiseMax(hi, c.hi) }
        return (lo, hi)
    }

    private static func hull(_ pts: [CGPoint]) -> [CGPoint] {
        let s = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard s.count > 2 else { return s }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in s { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }; lower.append(p) }
        for p in s.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }; upper.append(p) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static func drawView(_ ctx: CGContext, _ key: String, parts: [Part], in cell: CGRect, metric: Bool) {
        guard let v = views[key] else { return }
        var shapes: [(Part, [[CGPoint]], Double)] = []
        var lo = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity), hi = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        for p in parts {
            if p.profile != nil {
                let projected = Geo.polys(for: p).compactMap { poly -> [SIMD2<Double>]? in
                    let points = poly.pts.map { p.toWorld($0) }.map { SIMD2(v.h($0), v.v($0)) }
                    let area = Planar.signedArea(points)
                    guard abs(area) > 1e-9 else { return nil }
                    return area < 0 ? Array(points.reversed()) : points
                }
                let contours = Planar.union(projected).map { $0.map { CGPoint(x: $0.x, y: $0.y) } }
                for q in contours.flatMap({ $0 }) {
                    lo = CGPoint(x: min(lo.x, q.x), y: min(lo.y, q.y)); hi = CGPoint(x: max(hi.x, q.x), y: max(hi.y, q.y))
                }
                shapes.append((p, contours, v.depth(p.center)))
                continue
            }
            let e = extents(p)
            var pts: [CGPoint] = []
            for i in 0..<8 {
                let w = p.toWorld(SIMD3(i & 1 == 0 ? e.lo.x : e.hi.x, i & 2 == 0 ? e.lo.y : e.hi.y, i & 4 == 0 ? e.lo.z : e.hi.z))
                let q = CGPoint(x: v.h(w), y: v.v(w))
                pts.append(q)
                lo = CGPoint(x: min(lo.x, q.x), y: min(lo.y, q.y)); hi = CGPoint(x: max(hi.x, q.x), y: max(hi.y, q.y))
            }
            shapes.append((p, [hull(pts)], v.depth(p.center)))
        }
        text(v.name, at: CGPoint(x: cell.minX + 4, y: cell.maxY - 14), size: 10, bold: true)
        guard !shapes.isEmpty else { return }
        let rw = max(hi.x - lo.x, 1e-6), rh = max(hi.y - lo.y, 1e-6)
        let avail = cell.insetBy(dx: 36, dy: 36)
        let sc = min(avail.width / rw, avail.height / rh)
        let ox = avail.midX - (lo.x + hi.x) / 2 * sc, oy = avail.midY - (lo.y + hi.y) / 2 * sc
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sc + ox, y: p.y * sc + oy) }
        for (part, contours, _) in shapes.sorted(by: { $0.2 < $1.2 }) {
            ctx.beginPath()
            for poly in contours where poly.count >= 3 {
                ctx.addLines(between: poly.map(map)); ctx.closePath()
            }
            ctx.setFillColor(part.species.base.withAlphaComponent(0.55).cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(0.6)
            ctx.drawPath(using: .fillStroke)
            let centre = map(CGPoint(x:v.h(part.center),y:v.v(part.center)))
            text(ShopIdentity.label(part),at:centre,size:7,center:true)
        }
        let a = map(lo), b = map(hi)
        dim(ctx, CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: a.y), off: CGPoint(x: 0, y: -16), Units.format(rw, metric: metric))
        dim(ctx, CGPoint(x: b.x, y: a.y), CGPoint(x: b.x, y: b.y), off: CGPoint(x: 16, y: 0), Units.format(rh, metric: metric))
    }

    // MARK: Pages

    static func pdf(parts: [Part], title: String, metric: Bool, dimensions: [ModelDimension] = [],overviewOnly: Bool = false) -> Data {
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        func newPage(_ title: String, _ draw: () -> Void) {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text(title, at: CGPoint(x: 30, y: 580), size: 14, bold: true)
            text(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none),
                 at: CGPoint(x: 700, y: 584), size: 8, color: .darkGray)
            draw()
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }

        let rows = CutList.rows(parts)

        newPage("\(title) — Assembly") {
            let w = (page.width - 60) / 2, h = (page.height - 80) / 2
            drawView(ctx, "front", parts: parts, in: CGRect(x: 30, y: 30 + h, width: w, height: h), metric: metric)
            drawView(ctx, "right", parts: parts, in: CGRect(x: 30 + w, y: 30 + h, width: w, height: h), metric: metric)
            drawView(ctx, "top", parts: parts, in: CGRect(x: 30, y: 30, width: w, height: h), metric: metric)
            var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
            for p in parts { let b = p.bounds; lo = pointwiseMin(lo, b.lo); hi = pointwiseMax(hi, b.hi) }
            let o = parts.isEmpty ? SIMD3<Double>.zero : hi - lo
            let x = 30 + w + 20
            text("SUMMARY", at: CGPoint(x: x, y: 30 + h - 24), size: 10, bold: true)
            let f = { (v: Double) in Units.format(v, metric: metric) }
            let lines = ["Boards: \(parts.count)", "Overall width (X): \(f(o.x))", "Overall height (Y): \(f(o.y))",
                         "Overall depth (Z): \(f(o.z))", "Unique cut sizes: \(rows.count)"]
            for (i, l) in lines.enumerated() { text(l, at: CGPoint(x: x, y: 30 + h - 44 - CGFloat(i) * 13)) }
        }

        if overviewOnly { ctx.closePDF();return data as Data }

        // Cut list pages
        let perPage = 30
        for (pi, chunk) in stride(from: 0, to: max(rows.count, 1), by: perPage).map({ Array(rows.dropFirst($0).prefix(perPage)) }).enumerated() {
            newPage("\(title) — Cut List\(pi > 0 ? " (cont.)" : "")") {
                let cols: [(String, CGFloat)] = [("Qty", 30), ("Species", 80), ("Thick", 130), ("Width", 200), ("Length", 270), ("Parts", 350)]
                for (n, x) in cols { text(n, at: CGPoint(x: x, y: 550), size: 9, bold: true) }
                for (i, r) in chunk.enumerated() {
                    let y = 534 - CGFloat(i) * 16
                    let f = { (v: Double) in Units.format(v, metric: metric) }
                    let cells = ["\(r.qty)", r.species.rawValue, f(r.t), f(r.w), f(r.l), zip(r.labels,r.names).map { $0 + " " + $1 }.joined(separator:", ")]
                    for ((_, x), c) in zip(cols, cells) { text(String(c.prefix(c == cells.last ? 60 : 20)), at: CGPoint(x: x, y: y)) }
                }
                if pi == 0 {
                    let bf = rows.filter { !$0.species.isSheet }.reduce(0) { $0 + $1.boardFeet }
                    text(String(format: "Solid lumber: %.2f board feet (finished size)", bf), at: CGPoint(x: 30, y: 30), size: 9)
                }
            }
        }

        // One detail sheet per distinct board.
        for r in rows {
            guard let part = parts.first(where: { r.partIDs.contains($0.id) }) else { continue }
            let fp = Flatten.flat(part)
            newPage("\(r.labels.joined(separator:", ")) \(r.names.first ?? fp.name) — ×\(r.qty)") {
                drawFlat(ctx, fp, metric: metric, qty: r.qty, names: r.names)
            }
        }
        for start in stride(from: 0, to: dimensions.count, by: 30) {
            newPage("\(title) — Assembly dimensions") {
                for (i, dimension) in dimensions.dropFirst(start).prefix(30).enumerated() {
                    let label = dimension.name.isEmpty ? "Dimension \(start + i + 1)" : dimension.name
                    let a = dimension.a, b = dimension.b
                    text("\(label): \(Units.format(norm(b - a), metric: metric))", at: CGPoint(x: 30, y: 545 - CGFloat(i) * 16), size: 10)
                    text("X/Y/Z \(a) → \(b) (in)", at: CGPoint(x: 290, y: 545 - CGFloat(i) * 16), size: 8)
                }
            }
        }
        ctx.closePDF()
        return data as Data
    }

    private static func drawFlat(_ ctx: CGContext, _ fp: FlatPart, metric: Bool, qty: Int, names: [String]) {
        let f = { (v: Double) in Units.format(v, metric: metric) }
        let bounds = fp.footprint
        let blankLength = bounds.hi.x - bounds.lo.x, blankWidth = bounds.hi.y - bounds.lo.y
        text("\(fp.species.rawValue)   \(f(blankLength)) × \(f(blankWidth)) × \(f(fp.requiredThickness)) thick   (qty \(qty))", at: CGPoint(x: 30, y: 562), size: 10)
        if names.count > 1 { text(names.joined(separator: ", "), at: CGPoint(x: 30, y: 549), size: 8, color: .darkGray) }
        let area = CGRect(x: 80, y: 190, width: 640, height: 320)
        let sc = min(area.width / blankLength, area.height / blankWidth)
        let ox = area.midX - (bounds.lo.x + bounds.hi.x) * sc / 2
        let oy = area.midY - (bounds.lo.y + bounds.hi.y) * sc / 2
        func map(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: ox + p.x * sc, y: oy + p.y * sc) }
        func rect(_ r: (lo: SIMD2<Double>, hi: SIMD2<Double>)) -> CGRect {
            CGRect(x: ox + r.lo.x * sc, y: oy + r.lo.y * sc, width: (r.hi.x - r.lo.x) * sc, height: (r.hi.y - r.lo.y) * sc)
        }
        ctx.beginPath()
        for contour in fp.cutOutlines {
            ctx.addLines(between: contour.map(map))
            ctx.closePath()
        }
        ctx.setFillColor(fp.species.base.withAlphaComponent(0.5).cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1)
        ctx.drawPath(using: .fillStroke)
        var notes: [String] = []
        for ft in fp.features {
            let r = rect(ft.rect)
            let color: NSColor = ft.side == .top ? .systemBlue : (ft.side == .bottom ? .systemPurple : .systemOrange)
            ctx.setFillColor(color.withAlphaComponent(0.3).cgColor)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(0.8)
            if let points = ft.polygon {
                ctx.beginPath(); ctx.addLines(between: points.map(map)); ctx.closePath(); ctx.drawPath(using: .fillStroke)
            } else { ctx.fill(r); ctx.stroke(r) }
            let through = abs(ft.depth - fp.thickness) < 1e-6
            let side = ft.side == .top ? "top face" : (ft.side == .bottom ? "bottom face" : "edge/end")
            notes.append("\(ft.kind): \(f(ft.rect.hi.x - ft.rect.lo.x)) × \(f(ft.rect.hi.y - ft.rect.lo.y)), "
                         + (through ? "through" : "\(f(ft.depth)) deep") + " (\(side)), at \(f(ft.rect.lo.x)) from left, \(f(ft.rect.lo.y)) from bottom")
            text(through ? "through" : f(ft.depth), at: CGPoint(x: r.midX, y: r.midY - 3), size: 7, center: true, color: color)
        }
        for tn in fp.tenons {
            let r = rect(tn.rect)
            ctx.setStrokeColor(NSColor.systemPink.cgColor)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            if let polygon = tn.polygon {
                ctx.beginPath(); ctx.addLines(between: polygon.map(map)); ctx.closePath(); ctx.strokePath()
            } else { ctx.stroke(r) }
            ctx.setLineDash(phase: 0, lengths: [])
            notes.append("Tenon: \(f(tn.rect.hi.x - tn.rect.lo.x)) × \(f(tn.rect.hi.y - tn.rect.lo.y)), \(f(tn.depth)) thick, at \(f(tn.rect.lo.x)) from left")
        }
        let o = map(bounds.lo), e = map(bounds.hi)
        dim(ctx, o, CGPoint(x: e.x, y: o.y), off: CGPoint(x: 0, y: -18), f(blankLength))
        dim(ctx, CGPoint(x: e.x, y: o.y), e, off: CGPoint(x: 18, y: 0), f(blankWidth))
        for (i, n) in (notes + fp.notes).enumerated() { text(n, at: CGPoint(x: 30, y: 150 - CGFloat(i) * 12), size: 8) }
    }
}

extension Document {
    func exportDrawings() {
        guard prepareForExport() else { return }
        let parts = fabricationSelectionProject.parts
        guard !parts.isEmpty else { status = "Nothing to draw."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(fileName) drawings.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Drawing.pdf(parts: parts, title: fileName, metric: metric, dimensions: studio.dimensions).write(to: url, options: .atomic)
            status = "Saved \(url.lastPathComponent)"
            NSWorkspace.shared.open(url)
        } catch { status = "Could not save drawings: \(error.localizedDescription)" }
    }
}
