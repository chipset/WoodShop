import AppKit
import UniformTypeIdentifiers

// MARK: - 3D export (STL / OBJ)

enum Exporter3D {
    /// Convert model space (Y up) to the Z-up convention slicers and CAM tools expect.
    private static func zUp(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(v.x, -v.z, v.y) }

    private static func worldPolys(_ part: Part) -> [(pts: [SIMD3<Double>], n: SIMD3<Double>)] {
        Geo.polys(for: part).map { poly in
            (poly.pts.map { zUp(part.toWorld($0)) }, zUp(simdNormalize(part.dirToWorld(poly.n))))
        }
    }

    static func stl(_ parts: [Part], scale: Double) -> Data {
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for part in parts {
            for poly in worldPolys(part) {
                for i in 1..<(poly.pts.count - 1) { tris.append((poly.n, poly.pts[0], poly.pts[i], poly.pts[i + 1])) }
            }
        }
        var data = Data(count: 80)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        put(UInt32(tris.count))
        for (n, a, b, c) in tris {
            for v in [n, a * scale, b * scale, c * scale] { put(Float(v.x)); put(Float(v.y)); put(Float(v.z)) }
            put(UInt16(0))
        }
        return data
    }

    static func obj(_ parts: [Part], scale: Double) -> String {
        var out = "# WoodShop export (Z up, \(scale == 1 ? "inches" : "millimetres"))\n"
        var base = 1
        for part in parts {
            let name = part.name.components(separatedBy: .whitespacesAndNewlines.union(.controlCharacters)).joined(separator: "_")
            out += "o \(name)\n"
            for poly in worldPolys(part) {
                for p in poly.pts { out += String(format: "v %.5f %.5f %.5f\n", p.x * scale, p.y * scale, p.z * scale) }
                out += String(format: "vn %.5f %.5f %.5f\n", poly.n.x, poly.n.y, poly.n.z)
                out += "f " + (0..<poly.pts.count).map { "\(base + $0)" }.joined(separator: " ") + "\n"
                base += poly.pts.count
            }
        }
        return out
    }
}

// MARK: - Flattening for CNC

struct Feature {
    enum Side { case top, bottom, edge }
    var kind: String
    var side: Side
    var depth: Double
    var rect: (lo: SIMD2<Double>, hi: SIMD2<Double>)
    var polygon: [SIMD2<Double>]? = nil
    var reference: FeatureRef? = nil
    var islands: [[SIMD2<Double>]] = []
}

/// A board laid flat: thickness vertical, length along x, width along y.
struct FlatPart {
    var name: String
    var species: Species
    var thickness: Double, width: Double, length: Double
    var outline: [SIMD2<Double>]
    var features: [Feature]
    var tenons: [Feature]
    var notes: [String]
    var contours: [[SIMD2<Double>]] = []
    var stockThickness: Double? = nil
    var requiredThickness: Double { stockThickness ?? thickness }
    var allowRotation = false
    var sourceID: UUID? = nil
    var shopLabel: String? = nil
    var rotationDegrees = 0
    var flippedFace = false
    var grainMatchGroup: String? = nil
    var grainMatchOrder: Int? = nil
    func faceFlipped() -> FlatPart {
        var p = self
        func flip(_ point: SIMD2<Double>) -> SIMD2<Double> { SIMD2(point.x, width - point.y) }
        p.outline = outline.reversed().map(flip); p.contours = contours.map { $0.reversed().map(flip) }
        func feature(_ f: Feature) -> Feature {
            var n = f
            if f.side == .top { n.side = .bottom } else if f.side == .bottom { n.side = .top }
            let points = (f.polygon ?? [f.rect.lo,SIMD2(f.rect.hi.x,f.rect.lo.y),f.rect.hi,SIMD2(f.rect.lo.x,f.rect.hi.y)]).reversed().map(flip)
            n.polygon = points
            n.islands = f.islands.map { $0.reversed().map(flip) }
            n.rect = (points.reduce(points[0]) { SIMD2(min($0.x,$1.x),min($0.y,$1.y)) },points.reduce(points[0]) { SIMD2(max($0.x,$1.x),max($0.y,$1.y)) })
            return n
        }
        p.features = features.map(feature); p.tenons = tenons.map(feature); p.flippedFace.toggle()
        return p
    }
    func rotated() -> FlatPart {
        var p = self
        func turn(_ a: SIMD2<Double>) -> SIMD2<Double> { SIMD2(width - a.y, a.x) }
        p.length = width; p.width = length; p.rotationDegrees = (rotationDegrees + 90) % 360
        p.outline = outline.map(turn); p.contours = contours.map { $0.map(turn) }
        func feature(_ f: Feature) -> Feature {
            var n = f
            let points = (f.polygon ?? [f.rect.lo, SIMD2(f.rect.hi.x, f.rect.lo.y), f.rect.hi, SIMD2(f.rect.lo.x, f.rect.hi.y)]).map(turn)
            n.polygon = points
            n.islands = f.islands.map { $0.map(turn) }
            n.rect = (points.reduce(points[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }, points.reduce(points[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) })
            return n
        }
        p.features = features.map(feature); p.tenons = tenons.map(feature)
        return p
    }
    var cutOutlines: [[SIMD2<Double>]] { contours.isEmpty ? [outline] : contours }
    var footprint: (lo: SIMD2<Double>, hi: SIMD2<Double>) {
        let pts = cutOutlines.flatMap { $0 } + tenons.flatMap { [$0.rect.lo, $0.rect.hi] }
        let lo = pts.reduce(SIMD2<Double>.zero) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }
        let hi = pts.reduce(SIMD2(length, width)) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
        return (lo, hi)
    }
}

enum Flatten {
    static func flat(_ part: Part) -> FlatPart {
        let (t, w, l) = part.materialAxes
        let eps = 1e-6
        // Project the entire trimmed blank, including the long points of bevels.
        var blank = part
        blank.cuts = []; blank.operations = nil; blank.patterns = nil; blank.featureOrder = nil
        let blankContours: [[SIMD2<Double>]]
        if let profile = part.profile, part.trims.isEmpty, !part.hasEdgeProfiles, profile.thickness == t {
            let points = profile.contour(size: part.size).map { profile.local($0, depth: 0, size: part.size) }
                .map { SIMD2($0[l], $0[w]) }
            blankContours = [Planar.signedArea(points) < 0 ? Array(points.reversed()) : points]
        } else if part.profile != nil || part.mesh != nil {
            blankContours = projectedContours(Geo.polys(for: blank), u: l, v: w)
        } else {
            blankContours = [Planar.hull(Geo.polys(for: blank).flatMap { $0.pts }.map { SIMD2($0[l], $0[w]) })]
        }
        let outline = blankContours.max { abs(Planar.signedArea($0)) < abs(Planar.signedArea($1)) } ?? []

        var features: [Feature] = [], tenons: [Feature] = []
        for c in part.cuts where c.suppressed != true {
            let rect = (lo: SIMD2(max(c.lo[l], c.additive ? -1e9 : 0), max(c.lo[w], c.additive ? -1e9 : 0)),
                        hi: SIMD2(min(c.hi[l], c.additive ? 1e9 : part.size[l]), min(c.hi[w], c.additive ? 1e9 : part.size[w])))
            if c.additive {
                let projected = Planar.hull(Geo.polys(boxes: [Box(lo: c.lo, hi: c.hi)], planes: part.clipPlanes)
                    .flatMap { $0.pts }.map { SIMD2($0[l], $0[w]) })
                guard projected.count >= 3 else { continue }
                let lo = projected.reduce(projected[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }
                let hi = projected.reduce(projected[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
                tenons.append(Feature(kind: c.kind, side: .top, depth: c.hi[t] - c.lo[t], rect: (lo, hi), polygon: projected, reference:FeatureRef(part:part.id,kind:.cut,feature:c.id)))
                continue
            }
            guard rect.hi.x > rect.lo.x, rect.hi.y > rect.lo.y else { continue }
            let normal = c.faceAxis ?? t
            let side: Feature.Side = normal != t ? .edge : (c.hi[t] >= part.size[t] - eps ? .top : (c.lo[t] <= eps ? .bottom : .edge))
            let depthAxis = side == .edge ? (c.faceAxis ?? t) : t
            var shape: [SIMD2<Double>]? = (c.relief != nil || c.allowance != nil) ? c.machiningContour(part: part).map { pt in
                let a = c.faceAxis ?? t
                var point = SIMD3<Double>.zero; point[(a + 1) % 3] = pt.x; point[(a + 2) % 3] = pt.y
                return SIMD2(point[l], point[w])
            } : nil
            if let planes = c.planes {
                // An angled bore leaves an elliptical opening: use the hull of the clipped tool, limited to the board.
                let hull = Planar.hull(Geo.polys(boxes: [Box(lo: c.lo, hi: c.hi)], planes: planes.map { ($0.p, $0.n) })
                    .flatMap { $0.pts }.map { SIMD2(min(max($0[l], 0), part.size[l]), min(max($0[w], 0), part.size[w])) })
                if hull.count >= 3 { shape = hull }
            }
            features.append(Feature(kind: c.kind, side: side, depth: min(c.hi[depthAxis], part.size[depthAxis]) - max(c.lo[depthAxis], 0), rect: rect, polygon: shape, reference:FeatureRef(part:part.id,kind:.cut,feature:c.id)))
        }
        for op in part.machiningOperations where op.suppressed != true {
            let side: Feature.Side = op.axis == t ? (op.positive ? .top : .bottom) : .edge
            let points = op.contour.map { pt -> SIMD2<Double> in
                var p = SIMD3<Double>.zero; p[op.u] = pt.x; p[op.v] = pt.y
                return SIMD2(p[l], p[w])
            }
            let lo = points.reduce(points[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }
            let hi = points.reduce(points[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
            features.append(Feature(kind: op.kind, side: side, depth: op.depth, rect: (lo, hi), polygon: points, reference:FeatureRef(part:part.id,kind:op.patternID == nil ? .operation : .pattern,feature:op.patternID ?? op.id),islands:(op.islands ?? []).map { hole in hole.map { pt in var p = SIMD3<Double>.zero;p[op.u] = pt.x;p[op.v] = pt.y;return SIMD2(p[l],p[w]) } }))
        }
        var notes: [String] = []
        if part.mesh != nil { notes.append("General solid: projected outline only. Use STL/OBJ for full 3D machining.") }
        if part.machiningOperations.contains(where: { $0.bottomScale != 1 || $0.bottomStretch != nil && $0.bottomStretch != SIMD2(repeating: 1) }) {
            notes.append("Tapered operations require a matching countersink/dovetail tool or a 3D machining setup; their layers show the opening.")
        }
        if part.cuts.contains(where: { $0.relief != nil }) { notes.append("Cutter-sized corner reliefs are included in the pocket contours.") }
        if let profile = part.profile {
            notes.append("Curves are exported as polylines with a maximum subdivision deviation of 0.001in (0.0254mm).")
            if profile.thickness != t { notes.append("The curve is on an edge of the stock; it requires a separate machining setup.") }
        }
        if !part.trims.isEmpty { notes.append("Angled cuts: outline is the full projected blank; bevels require a separate setup.") }
        if part.hasEdgeProfiles { notes.append("Chamfers, roundovers and arches: the outline is the full projected blank; machine the profile in a separate setup.") }
        if part.cuts.contains(where: { $0.planes != nil && $0.suppressed != true }) { notes.append("Angled bores (pocket holes) are drilled with a jig; the layer shows the opening.") }
        if !tenons.isEmpty { notes.append("Tenons are merged into OUTLINE; TENON marks their shoulder regions. Reduced-thickness tenons require shoulder machining.") }
        if features.contains(where: { $0.side == .bottom }) { notes.append("Some pockets are on the bottom face (flip the stock).") }
        if features.contains(where: { $0.side == .edge }) { notes.append("Some cuts are on an edge/end face and need a separate setup.") }
        let contours = tenons.isEmpty ? blankContours.filter { $0.count >= 3 } : Planar.union(blankContours + tenons.compactMap(\.polygon))
        let tMin = part.cuts.filter { $0.additive && $0.suppressed != true }.map { $0.lo[t] }.reduce(0, min)
        let tMax = part.cuts.filter { $0.additive && $0.suppressed != true }.map { $0.hi[t] }.reduce(part.size[t], max)
        let stockThickness = tMax - tMin
        if stockThickness > part.size[t] + eps {
            notes.append("Tenons extend beyond the board thickness: use a \(Units.decimal(stockThickness))in thick blank and machine the shoulders in a separate setup.")
        }
        if contours.isEmpty { notes.append("No valid cutting outline could be generated.") }
        var flat = FlatPart(name: part.name, species: part.species, thickness: part.size[t], width: part.size[w],
                        length: part.size[l], outline: outline, features: features, tenons: tenons, notes: notes, contours: contours, stockThickness: stockThickness, allowRotation: part.allowNestingRotation ?? false, sourceID: part.id, shopLabel:ShopIdentity.label(part))
        flat.grainMatchGroup = part.shop?.grainMatchGroup
        flat.grainMatchOrder = part.shop?.grainMatchOrder
        if part.cncTopPositive == false {
            flat = flat.faceFlipped()
            flat.notes.removeAll { $0 == "Some pockets are on the bottom face (flip the stock)." }
            if flat.features.contains(where: { $0.side == .bottom }) { flat.notes.append("Some pockets are on the bottom face (flip the stock).") }
            flat.notes.append("CNC top is the negative \(FaceRef.axisNames[t]) face; the width direction is flipped in the layout.")
        }
        return flat
    }

    static func projectedContours(_ polygons: [Geo.Poly], u: Int, v: Int) -> [[SIMD2<Double>]] {
        let projected = polygons.compactMap { poly -> [SIMD2<Double>]? in
            let points = poly.pts.map { SIMD2($0[u], $0[v]) }
            let area = Planar.signedArea(points)
            guard abs(area) > 1e-9 else { return nil }
            return area < 0 ? Array(points.reversed()) : points
        }
        return Planar.union(projected)
    }
}

// MARK: - Nesting

struct Placed {
    var part: FlatPart
    var x: Double, y: Double
    var sheet: Int
    var group: String
}

enum Nesting {
    static func groupLabel(_ key: String, metric: Bool) -> String {
        guard let space = key.lastIndex(of: " "), key.hasSuffix("in"), let thickness = Double(key[key.index(after:space)...].dropLast(2)) else { return key }
        return String(key[..<space]) + " · " + Units.format(thickness,metric:metric)
    }
    struct Result { var placed: [Placed]; var sheets: [(group: String, index: Int, x: Double)]; var sheetL: Double; var sheetW: Double; var oversize: [String];var stockRecords: [Int:SheetStock]? = nil }

    /// Shelf packing, one set of sheets per species+thickness. Sheets sit side by side along +x.
    static func nest(_ parts: [FlatPart], sheetL: Double, sheetW: Double, gap: Double, registration: Registration? = nil,stocks: [SheetStock] = []) -> Result {
        guard ModelValidation.nesting(sheetL:sheetL,sheetW:sheetW,gap:gap,registration:registration) == nil else { return Result(placed:[],sheets:[],sheetL:sheetL,sheetW:sheetW,oversize:parts.map(\.name)) }
        let a = SheetPacker.nest(parts,sheetL:sheetL,sheetW:sheetW,gap:gap,registration:registration,stocks:stocks,areaFirst:true)
        let b = SheetPacker.nest(parts,sheetL:sheetL,sheetW:sheetW,gap:gap,registration:registration,stocks:stocks,areaFirst:false)
        let best: Result
        if a.oversize.count != b.oversize.count { best = a.oversize.count<b.oversize.count ? a : b }
        else if a.sheets.count != b.sheets.count { best = a.sheets.count<b.sheets.count ? a : b }
        else { best = a.utilization>=b.utilization ? a : b }
        if !stocks.isEmpty || parts.contains(where: { !($0.grainMatchGroup ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) { return best }
        let old = shelfPack(parts,sheetL:sheetL,sheetW:sheetW,gap:gap,registration:registration)
        return old.sheets.count<best.sheets.count && old.oversize.count<=best.oversize.count ? old : best
    }
    static func shelfPack(_ parts: [FlatPart], sheetL: Double, sheetW: Double, gap: Double, registration: Registration? = nil) -> Result {
        guard ModelValidation.nesting(sheetL: sheetL, sheetW: sheetW, gap: gap, registration: registration) == nil else {
            return Result(placed: [], sheets: [], sheetL: sheetL, sheetW: sheetW, oversize: parts.map(\.name))
        }
        let strip = registration?.enabled == true ? registration!.inset + registration!.diameter / 2 + gap : 0
        let startX = gap + strip
        var groups: [String: [FlatPart]] = [:]
        var order: [String] = []
        for p in parts {
            let key = "\(p.species.rawValue) \(p.requiredThickness)in"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(p)
        }
        var res = Result(placed: [], sheets: [], sheetL: sheetL, sheetW: sheetW, oversize: [])
        var sheetNo = 0
        for key in order {
            var list = groups[key]!.sorted { ($0.length, $0.width) > ($1.length, $1.width) }
            var x = startX, y = gap, rowH = 0.0
            var sheetInGroup = 0
            func newSheet() {
                res.sheets.append((key, sheetInGroup, Double(sheetNo) * (sheetL + 24)))
                sheetNo += 1; sheetInGroup += 1
                x = startX; y = gap; rowH = 0
            }
            newSheet()
            var firstOnSheet = true
            while !list.isEmpty {
                var p = list.removeFirst()
                if p.allowRotation {
                    let original = p.footprint, rotated = p.rotated(), b = rotated.footprint
                    let fitsOriginal = original.hi.x - original.lo.x + 2 * gap + strip <= sheetL && original.hi.y - original.lo.y + 2 * gap <= sheetW
                    let fitsRotated = b.hi.x - b.lo.x + 2 * gap + strip <= sheetL && b.hi.y - b.lo.y + 2 * gap <= sheetW
                    if fitsRotated && (!fitsOriginal || (x + b.hi.x - b.lo.x + gap <= sheetL && b.hi.y - b.lo.y < original.hi.y - original.lo.y)) { p = rotated }
                }
                let bounds = p.footprint
                let length = bounds.hi.x - bounds.lo.x, width = bounds.hi.y - bounds.lo.y
                if length + 2 * gap + strip > sheetL || width + 2 * gap > sheetW {
                    res.oversize.append(p.name)
                    continue
                }
                if x + length + gap > sheetL && x > startX {
                    x = startX; y += rowH + gap; rowH = 0
                }
                if y + width + gap > sheetW && !firstOnSheet {
                    newSheet(); firstOnSheet = true
                }
                res.placed.append(Placed(part: p, x: res.sheets.last!.x + x - bounds.lo.x, y: y - bounds.lo.y, sheet: sheetNo - 1, group: key))
                x += length + gap
                rowH = max(rowH, width)
                firstOnSheet = false
            }
        }
        return res
    }
}

// MARK: - DXF / SVG output

enum Prim {
    case poly(layer: String, pts: [SIMD2<Double>])
    case text(layer: String, at: SIMD2<Double>, size: Double, string: String)
}

enum CNCSetup: String, CaseIterable, Identifiable { case combined = "All operations", top = "Top setup", bottom = "Bottom setup (flipped)"; var id: String { rawValue } }

enum CNCOut {
    static func prims(_ r: Nesting.Result, metric: Bool, setup: CNCSetup = .combined, registration: Registration? = nil) -> [Prim] {
        func d(_ x: Double) -> String { Units.decimal(metric ? x * 25.4 : x) + (metric ? "mm" : "in") }
        var out: [Prim] = []
        for (index,s) in r.sheets.enumerated() {
            let o = SIMD2(s.x, 0.0),length = r.stock(at:index)?.length ?? r.sheetL,width = r.stock(at:index)?.width ?? r.sheetW
            out.append(.poly(layer: "SHEET", pts: [o, o + SIMD2(length, 0), o + SIMD2(length, width), o + SIMD2(0, width)]))
            out.append(.text(layer: "LABELS", at: o + SIMD2(0, width + 1), size: 1.5, string: "\(Nesting.groupLabel(s.group,metric:metric)) sheet \(s.index + 1)"))
        }
        for p in r.placed {
            let o = SIMD2(p.x, p.y)
            for contour in p.part.cutOutlines { out.append(.poly(layer: setup == .bottom ? "REFERENCE_OUTLINE" : "OUTLINE", pts: contour.map { $0 + o })) }
            for f in p.part.features {
                if setup == .top && f.side != .top { continue }
                if setup == .bottom && f.side != .bottom { continue }
                let tag = f.side == .top ? "POCKET" : (f.side == .bottom ? "POCKET_BOTTOM" : "SIDE")
                let through = abs(f.depth - p.part.thickness) < 1e-6
                let operation = ["Drill", "Counterbore", "Countersink", "Dovetail"].contains(f.kind) ? "_" + f.kind.uppercased() : ""
                let layer = through && f.side == .top && operation.isEmpty ? "CUTOUT_THROUGH" : "\(tag)\(operation)_\(d(f.depth))"
                let (a, b) = (f.rect.lo + o, f.rect.hi + o)
                out.append(.poly(layer: layer, pts: f.polygon.map { $0.map { $0 + o } } ?? [a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y)]))
                for island in f.islands { out.append(.poly(layer:layer,pts:island.map { $0+o })) }
            }
            for f in p.part.tenons where setup != .bottom {
                let (a, b) = (f.rect.lo + o, f.rect.hi + o)
                out.append(.poly(layer: "TENON", pts: f.polygon.map { $0.map { $0 + o } } ?? [a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y)]))
            }
            out.append(.text(layer: "LABELS", at: o + SIMD2(0.5, 0.5), size: min(1.0, p.part.width / 4), string: (p.part.shopLabel.map { $0 + " " } ?? "") + p.part.name))
        }
        if let registration, registration.enabled {
            for (index,sheet) in r.sheets.enumerated() {
                for y in [registration.inset, (r.stock(at:index)?.width ?? r.sheetW) - registration.inset] {
                    out.append(.poly(layer: "REGISTRATION_DRILL", pts: MeshTools.circle(center: SIMD2(sheet.x + registration.inset, y), radius: registration.diameter / 2)))
                }
            }
        }
        if setup == .bottom {
            out = out.map { prim in
                func flip(_ p: SIMD2<Double>) -> SIMD2<Double> {
                    let index = r.sheets.indices.first { p.x>=r.sheets[$0].x-1e-7 && p.x<=r.sheets[$0].x+(r.stock(at:$0)?.length ?? r.sheetL)+1e-7 }
                    return SIMD2(p.x,(index.flatMap { r.stock(at:$0)?.width } ?? r.sheetW)-p.y)
                }
                switch prim {
                case .poly(let layer, let pts): return .poly(layer: layer, pts: pts.map(flip))
                case .text(let layer, let at, let size, let string): return .text(layer: layer, at: flip(at), size: size, string: string)
                }
            }
        }
        return out
    }

    private static let colors: [String: Int] = ["SHEET": 8, "OUTLINE": 7, "LABELS": 3, "TENON": 6, "CUTOUT_THROUGH": 1]

    static func dxf(_ prims: [Prim], metric: Bool) -> String {
        let s = metric ? 25.4 : 1.0
        var layers: [String] = []
        for p in prims {
            let l: String
            switch p { case .poly(let layer, _): l = layer; case .text(let layer, _, _, _): l = layer }
            if !layers.contains(l) { layers.append(l) }
        }
        var o = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$INSUNITS\n70\n\(metric ? 4 : 1)\n0\nENDSEC\n"
        o += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLTYPE\n70\n1\n0\nLTYPE\n2\nCONTINUOUS\n70\n0\n3\nSolid line\n72\n65\n73\n0\n40\n0.0\n0\nENDTAB\n"
        o += "0\nTABLE\n2\nLAYER\n70\n\(layers.count)\n"
        for (i, l) in layers.enumerated() {
            let c = colors[l] ?? (l.hasPrefix("POCKET") ? 5 : (l.hasPrefix("SIDE") ? 4 : 2 + i % 5))
            o += "0\nLAYER\n2\n\(l)\n70\n0\n62\n\(c)\n6\nCONTINUOUS\n"
        }
        o += "0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        for p in prims {
            switch p {
            case .poly(let layer, let pts):
                o += "0\nPOLYLINE\n8\n\(layer)\n66\n1\n70\n1\n"
                for v in pts { o += "0\nVERTEX\n8\n\(layer)\n10\n\(String(format: "%.5f", v.x * s))\n20\n\(String(format: "%.5f", v.y * s))\n30\n0.0\n" }
                o += "0\nSEQEND\n8\n\(layer)\n"
            case .text(let layer, let at, let size, let string):
                let string = string.components(separatedBy: .controlCharacters).joined(separator: " ")
                o += "0\nTEXT\n8\n\(layer)\n10\n\(String(format: "%.5f", at.x * s))\n20\n\(String(format: "%.5f", at.y * s))\n30\n0.0\n40\n\(String(format: "%.4f", size * s))\n1\n\(string)\n"
            }
        }
        return o + "0\nENDSEC\n0\nEOF\n"
    }

    static func xmlEscaped(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func svg(_ prims: [Prim], sheetL: Double, sheetW: Double, count: Int, metric: Bool) -> String {
        let s = metric ? 25.4 : 1.0
        let totalW = Double(count) * (sheetL + 24) * s, totalH = (sheetW + 6) * s
        func y(_ v: Double) -> Double { totalH - v * s }
        let style: [String: String] = ["SHEET": "#888", "OUTLINE": "#000", "TENON": "#a0a", "CUTOUT_THROUGH": "#d00", "LABELS": "#080"]
        var o = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(totalW)\(metric ? "mm" : "in")\" height=\"\(totalH)\(metric ? "mm" : "in")\" viewBox=\"0 0 \(totalW) \(totalH)\">\n"
        for (index, p) in prims.enumerated() {
            switch p {
            case .poly(let layer, let pts):
                let color = style[layer] ?? (layer.hasPrefix("POCKET") ? "#06c" : "#09c")
                let d = pts.enumerated().map { "\($0.offset == 0 ? "M" : "L")\(String(format: "%.4f", $0.element.x * s)),\(String(format: "%.4f", y($0.element.y)))" }.joined(separator: " ") + " Z"
                o += "<path id=\"\(xmlEscaped(layer))-\(index)\" data-layer=\"\(xmlEscaped(layer))\" d=\"\(d)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(0.04 * s)\"/>\n"
            case .text(_, let at, let size, let string):
                o += "<text x=\"\(at.x * s)\" y=\"\(y(at.y))\" font-size=\"\(size * s)\" fill=\"#080\">\(xmlEscaped(string))</text>\n"
            }
        }
        return o + "</svg>\n"
    }
}

// MARK: - Document hooks (save panels)

extension Document {
    private func savePanel(_ name: String, _ type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    func export3D(format: String) {
        guard prepareForExport() else { return }
        let exportProject = fabricationSelectionProject
        let parts = exportProject.parts
        guard !parts.isEmpty else { status = "Nothing to export."; return }
        do { try ModelValidation.validate(exportProject) }
        catch { status = "Export blocked: \(error.localizedDescription)"; return }
        let ext = format.hasPrefix("obj") ? "obj" : "stl"
        guard let url = savePanel("\(fileName).\(ext)", UTType(filenameExtension: ext) ?? .data) else { return }
        let mm = format.hasSuffix("mm")
        let scale = mm ? 25.4 : 1.0
        do {
            if format.hasPrefix("obj") {
                try Exporter3D.obj(parts, scale: scale).write(to: url, atomically: true, encoding: .utf8)
            } else {
                try Exporter3D.stl(parts, scale: scale).write(to:url,options:.atomic)
            }
            status = "Exported \(url.lastPathComponent)"
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }

    /// Flatten every board, nest onto sheets and write DXF (VCarve) or SVG.
    func exportFlat(svg: Bool) {
        guard prepareForExport() else { return }
        if !showCutList || makeArea != .fabrication || fabricationTab != 1 {
            openMake(.sheets)
            status = "Review the sheet layout, then choose Export DXF or Export SVG."
            return
        }
        let exportProject = fabricationSelectionProject
        let errors = MachiningReview.issues(project:exportProject).filter { $0.severity == .error }
        guard errors.isEmpty else { status = "CNC export blocked: " + errors.map(\.message).joined(separator:" "); return }
        finishDrag?()
        guard !exportProject.parts.isEmpty else { status = "Nothing to export."; return }
        do { try ModelValidation.validate(exportProject) }
        catch { status = "Export blocked: \(error.localizedDescription)"; return }
        let flat = exportProject.parts.filter { $0.hardware != true }.map(Flatten.flat)
        let r = Nesting.nest(flat, sheetL: sheetLength, sheetW: sheetWidth, gap: nestGap, registration: studio.registration,stocks:studio.nestingStocks)
        guard r.oversize.isEmpty else {
            let alert = NSAlert(); alert.messageText = "Parts do not fit the sheet"
            alert.informativeText = r.oversize.joined(separator: ", ") + ". Increase the sheet size or revise the parts before exporting."
            alert.runModal(); return
        }
        guard !flat.contains(where: { $0.contours.isEmpty }) else { status = "Export blocked: a board has no valid cutting outline."; return }
        let notes = flat.flatMap { p in p.notes.map { "\(p.name): \($0)" } }
        if !notes.isEmpty {
            let alert = NSAlert(); alert.messageText = "Review machining setups"
            alert.informativeText = notes.joined(separator: "\n")
            alert.addButton(withTitle: "Export reviewed layout"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let prims = CNCOut.prims(r, metric: metric, setup: cncSetup, registration: studio.registration)
        guard let url = savePanel("\(fileName) flat.\(svg ? "svg" : "dxf")",
                                  UTType(filenameExtension: svg ? "svg" : "dxf") ?? .data) else { return }
        let text = svg ? CNCOut.svg(prims, sheetL: sheetLength, sheetW: sheetWidth, count: r.sheets.count, metric: metric)
                       : CNCOut.dxf(prims, metric: metric)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = "Exported \(url.lastPathComponent) — \(r.placed.count) parts on \(r.sheets.count) sheet(s), units: \(metric ? "mm" : "inches")"
                + (r.oversize.isEmpty ? "" : ". Too big for the sheet: \(r.oversize.joined(separator: ", "))")
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }
}
