import Foundation
import simd

/// Boundary CSG for profiled boards. Every input face is convex and wound outward.
/// Rectangular boards keep their existing, cheaper box-subtraction path.
enum SolidCSG {
    private static let eps = 1e-7
    private struct Plane {
        var normal: SIMD3<Double>
        var distance: Double
        init(_ poly: Geo.Poly) { normal = poly.n; distance = simd_dot(poly.n, poly.pts[0]) }
        mutating func flip() { normal = -normal; distance = -distance }

        func split(_ poly: Geo.Poly) -> (same: [Geo.Poly], opposite: [Geo.Poly], front: [Geo.Poly], back: [Geo.Poly]) {
            let types = poly.pts.map { p -> Int in
                let d = simd_dot(normal, p) - distance
                return d < -eps ? 2 : (d > eps ? 1 : 0)
            }
            switch types.reduce(0, |) {
            case 0: return simd_dot(normal, poly.n) > 0 ? ([poly], [], [], []) : ([], [poly], [], [])
            case 1: return ([], [], [poly], [])
            case 2: return ([], [], [], [poly])
            default:
                var front: [SIMD3<Double>] = [], back: [SIMD3<Double>] = []
                for i in poly.pts.indices {
                    let j = (i + 1) % poly.pts.count, a = poly.pts[i], b = poly.pts[j]
                    if types[i] != 2 { front.append(a) }
                    if types[i] != 1 { back.append(a) }
                    if types[i] | types[j] == 3 {
                        let t = (distance - simd_dot(normal, a)) / simd_dot(normal, b - a)
                        let p = a + (b - a) * t
                        front.append(p); back.append(p)
                    }
                }
                return ([], [], face(front, normal: poly.n, source: poly.source).map { [$0] } ?? [], face(back, normal: poly.n, source: poly.source).map { [$0] } ?? [])
            }
        }
    }

    static func face(_ points: [SIMD3<Double>], normal: SIMD3<Double>, source: UUID? = nil) -> Geo.Poly? {
        guard ModelValidation.finite(normal),norm(normal) > 1e-10,points.allSatisfy(ModelValidation.finite) else { return nil }
        let normal = simdNormalize(normal)
        var clean: [SIMD3<Double>] = []
        for p in points where clean.last.map({ simd_length_squared(p - $0) > eps * eps }) ?? true { clean.append(p) }
        if clean.count > 1, simd_length_squared(clean[0] - clean.last!) <= eps * eps { clean.removeLast() }
        guard clean.count >= 3 else { return nil }
        let area = clean.indices.reduce(SIMD3<Double>.zero) { $0 + simd_cross(clean[$1] - clean[0], clean[($1 + 1) % clean.count] - clean[0]) }
        guard simd_length_squared(area) > 1e-20 else { return nil }
        if simd_dot(area, normal) < 0 { clean.reverse() }
        return Geo.Poly(pts: clean, n: normal, source: source)
    }

    private final class Tree {
        var plane: Plane?
        var faces: [Geo.Poly] = []
        var front: Tree?
        var back: Tree?
        init(_ polygons: [Geo.Poly] = []) { build(polygons) }
        var all: [Geo.Poly] { faces + (front?.all ?? []) + (back?.all ?? []) }
        func invert() {
            faces = faces.map { Geo.Poly(pts: $0.pts.reversed(), n: -$0.n, source: $0.source) }
            plane?.flip(); front?.invert(); back?.invert()
            swap(&front, &back)
        }
        func clip(_ polygons: [Geo.Poly]) -> [Geo.Poly] {
            guard let plane else { return polygons }
            var f: [Geo.Poly] = [], b: [Geo.Poly] = []
            for poly in polygons {
                let split = plane.split(poly)
                f += split.same + split.front; b += split.opposite + split.back
            }
            if let front { f = front.clip(f) }
            b = back?.clip(b) ?? []
            return f + b
        }
        func clipTo(_ other: Tree) {
            faces = other.clip(faces); front?.clipTo(other); back?.clipTo(other)
        }
        func build(_ polygons: [Geo.Poly]) {
            guard !polygons.isEmpty else { return }
            if plane == nil { plane = Plane(polygons[0]) }
            var f: [Geo.Poly] = [], b: [Geo.Poly] = []
            for poly in polygons {
                let split = plane!.split(poly)
                faces += split.same + split.opposite; f += split.front; b += split.back
            }
            if !f.isEmpty { if front == nil { front = Tree() }; front!.build(f) }
            if !b.isEmpty { if back == nil { back = Tree() }; back!.build(b) }
        }
    }

    static func subtract(_ left: [Geo.Poly], _ right: [Geo.Poly]) -> [Geo.Poly] {
        guard !left.isEmpty, !right.isEmpty else { return left }
        let a = Tree(left), b = Tree(right)
        a.invert(); a.clipTo(b); b.clipTo(a); b.invert(); b.clipTo(a); b.invert()
        a.build(b.all); a.invert()
        return a.all
    }
    static func union(_ left: [Geo.Poly], _ right: [Geo.Poly]) -> [Geo.Poly] {
        if left.isEmpty { return right }; if right.isEmpty { return left }
        let a = Tree(left), b = Tree(right)
        a.clipTo(b); b.clipTo(a); b.invert(); b.clipTo(a); b.invert(); a.build(b.all)
        return a.all
    }
    static func intersection(_ left: [Geo.Poly], _ right: [Geo.Poly]) -> [Geo.Poly] {
        guard !left.isEmpty, !right.isEmpty else { return [] }
        let a = Tree(left), b = Tree(right)
        a.invert(); b.clipTo(a); b.invert(); a.clipTo(b); b.clipTo(a); a.build(b.all); a.invert()
        return a.all
    }

    static func extrusion(_ profile: BoardProfile, size: SIMD3<Double>) -> [Geo.Poly] {
        let points = profile.contour(size: size), t = profile.thickness
        var normal = SIMD3<Double>.zero; normal[t] = 1
        var faces: [Geo.Poly] = []
        for triangle in Planar.triangulate(points) {
            for positive in [false, true] {
                let cap = triangle.map { profile.local($0, depth: positive ? size[t] : 0, size: size) }
                if let f = face(cap, normal: positive ? normal : -normal) { faces.append(f) }
            }
        }
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count], d = b - a
            var n = SIMD3<Double>.zero; n[profile.u] = d.y; n[profile.v] = -d.x
            let side = [profile.local(a, depth: 0, size: size), profile.local(b, depth: 0, size: size),
                        profile.local(b, depth: size[t], size: size), profile.local(a, depth: size[t], size: size)]
            if let f = face(side, normal: simd_normalize(n)) { faces.append(f) }
        }
        return faces
    }

    static func polys(for part: Part) -> [Geo.Poly] {
        var result = part.mesh?.polygons(size: part.size)
            ?? part.profile.map { extrusion($0, size: part.size) }
            ?? Geo.polys(boxes: [Box(lo: .zero, hi: part.size)], planes: [])
        for cut in part.cuts where cut.suppressed != true {
            if cut.additive { result = union(result, Geo.polys(boxes: [Box(lo: cut.lo, hi: cut.hi)], planes: [])) }
            else { result = subtract(result, cut.relief != nil || cut.allowance != nil ? cut.machiningPolygons(part: part) : Geo.polys(boxes: [Box(lo: cut.lo, hi: cut.hi)], planes: [])) }
        }
        for operation in part.machiningOperations where operation.suppressed != true {
            let tool = operation.polygons(size:part.size).map { p -> Geo.Poly in var p = p; p.source = operation.patternID ?? operation.id; return p }
            result = subtract(result,tool)
        }
        if !part.trims.isEmpty {
            var lo = SIMD3<Double>.zero, hi = part.size
            for cut in part.cuts where cut.additive && cut.suppressed != true { lo = pointwiseMin(lo, cut.lo); hi = pointwiseMax(hi, cut.hi) }
            // The padding avoids coincident outer faces; only the trim planes affect the result.
            let clipper = Geo.polys(boxes: [Box(lo: lo - 1, hi: hi + 1)], planes: part.trimPlanes)
            result = intersection(result, clipper)
        }
        return result
    }
}
