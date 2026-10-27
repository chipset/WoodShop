import Foundation
import simd

/// A closed Bézier outline in a board-local plane. Normalized coordinates scale with the blank.
struct BoardProfile: Codable, Equatable {
    struct Node: Codable, Equatable {
        var point: SIMD2<Double>
        var incoming: SIMD2<Double>? = nil
        var outgoing: SIMD2<Double>? = nil
    }
    enum Preset: String, CaseIterable, Identifiable {
        case rounded = "Rounded corners", oval = "Oval", arch = "Arch", rail = "Curved rail"
        var id: String { rawValue }
    }
    var u: Int
    var v: Int
    var nodes: [Node]
    var thickness: Int { 3 - u - v }
    static let tolerance = 0.001 // inches; shared by the viewport and fabrication exports

    static func preset(_ preset: Preset, part: Part) -> BoardProfile {
        let axes = part.materialAxes
        let k = 0.5522847498307936
        var nodes: [Node]
        switch preset {
        case .oval:
            nodes = [Node(point: SIMD2(1, 0.5), incoming: SIMD2(1, 0.5 - k / 2), outgoing: SIMD2(1, 0.5 + k / 2)),
                     Node(point: SIMD2(0.5, 1), incoming: SIMD2(0.5 + k / 2, 1), outgoing: SIMD2(0.5 - k / 2, 1)),
                     Node(point: SIMD2(0, 0.5), incoming: SIMD2(0, 0.5 + k / 2), outgoing: SIMD2(0, 0.5 - k / 2)),
                     Node(point: SIMD2(0.5, 0), incoming: SIMD2(0.5 - k / 2, 0), outgoing: SIMD2(0.5 + k / 2, 0))]
        case .rounded:
            let radius = min(part.size[axes.l], part.size[axes.w]) * 0.2
            let x = radius / part.size[axes.l], y = radius / part.size[axes.w]
            nodes = [Node(point: SIMD2(x, 0), incoming: SIMD2(x * (1 - k), 0)),
                     Node(point: SIMD2(1 - x, 0), outgoing: SIMD2(1 - x * (1 - k), 0)),
                     Node(point: SIMD2(1, y), incoming: SIMD2(1, y * (1 - k))),
                     Node(point: SIMD2(1, 1 - y), outgoing: SIMD2(1, 1 - y * (1 - k))),
                     Node(point: SIMD2(1 - x, 1), incoming: SIMD2(1 - x * (1 - k), 1)),
                     Node(point: SIMD2(x, 1), outgoing: SIMD2(x * (1 - k), 1)),
                     Node(point: SIMD2(0, 1 - y), incoming: SIMD2(0, 1 - y * (1 - k))),
                     Node(point: SIMD2(0, y), outgoing: SIMD2(0, y * (1 - k)))]
        case .arch:
            nodes = [Node(point: SIMD2(0, 0)), Node(point: SIMD2(1, 0)),
                     Node(point: SIMD2(1, 0.5), outgoing: SIMD2(1, 0.5 + k / 2)),
                     Node(point: SIMD2(0.5, 1), incoming: SIMD2(0.5 + k / 2, 1), outgoing: SIMD2(0.5 - k / 2, 1)),
                     Node(point: SIMD2(0, 0.5), incoming: SIMD2(0, 0.5 + k / 2))]
        case .rail:
            nodes = [Node(point: SIMD2(0, 0), outgoing: SIMD2(0.3, 0.65)),
                     Node(point: SIMD2(1, 0), incoming: SIMD2(0.7, 0.65)),
                     Node(point: SIMD2(1, 0.5), outgoing: SIMD2(0.7, 1)),
                     Node(point: SIMD2(0, 0.5), incoming: SIMD2(0.3, 1))]
        }
        return BoardProfile(u: axes.l, v: axes.w, nodes: nodes)
    }

    func local(_ point: SIMD2<Double>, depth: Double, size: SIMD3<Double>) -> SIMD3<Double> {
        var p = SIMD3<Double>.zero
        p[u] = point.x; p[v] = point.y; p[thickness] = depth
        return p
    }

    /// Adaptive subdivision bounds the distance from a curve to its polyline in model units.
    func contour(size: SIMD3<Double>) -> [SIMD2<Double>] {
        let scale = SIMD2(size[u], size[v])
        var points: [SIMD2<Double>] = []
        func distance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            let d = b - a, length = simd_length_squared(d)
            let t = length > 1e-20 ? max(0, min(1, simd_dot(p - a, d) / length)) : 0
            return simd_length(p - (a + t * d))
        }
        func flatten(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>, _ depth: Int) {
            if depth >= 14 || max(distance(b, a, d), distance(c, a, d)) <= Self.tolerance {
                points.append(d); return
            }
            let ab = (a + b) / 2, bc = (b + c) / 2, cd = (c + d) / 2
            let abc = (ab + bc) / 2, bcd = (bc + cd) / 2, mid = (abc + bcd) / 2
            flatten(a, ab, abc, mid, depth + 1); flatten(mid, bcd, cd, d, depth + 1)
        }
        guard let first = nodes.first else { return [] }
        points.append(first.point * scale)
        for i in nodes.indices {
            let a = nodes[i], b = nodes[(i + 1) % nodes.count]
            if a.outgoing == nil && b.incoming == nil { points.append(b.point * scale) }
            else { flatten(a.point * scale, (a.outgoing ?? a.point) * scale,
                           (b.incoming ?? b.point) * scale, b.point * scale, 0) }
        }
        points.removeLast() // closed implicitly
        return Planar.signedArea(points) < 0 ? points.reversed() : points
    }

    func validation(size: SIMD3<Double>) -> String? {
        guard (0..<3).contains(u), (0..<3).contains(v), u != v else { return "Invalid curve plane." }
        guard (3...64).contains(nodes.count) else { return "An outline needs between 3 and 64 points." }
        for node in nodes {
            for p in [node.point, node.incoming, node.outgoing].compactMap({ $0 }) {
                guard p.x.isFinite, p.y.isFinite, (0...1).contains(p.x), (0...1).contains(p.y) else {
                    return "Keep outline points and handles inside the board blank."
                }
            }
        }
        let points = contour(size: size)
        guard points.count <= 4096 else { return "This outline is too complex. Use fewer curves or a smaller blank." }
        guard Planar.isSimple(points), Planar.signedArea(points) > 1e-7 else {
            return "The outline must enclose an area without crossing or touching itself."
        }
        return nil
    }

    func rotated90(axis: Int) -> BoardProfile {
        let a = (axis + 1) % 3, b = (axis + 2) % 3
        var result = self
        result.u = u == a ? b : (u == b ? a : u)
        result.v = v == a ? b : (v == b ? a : v)
        func rotate(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(u == b ? 1 - p.x : p.x, v == b ? 1 - p.y : p.y)
        }
        result.nodes = nodes.map { Node(point: rotate($0.point), incoming: $0.incoming.map(rotate), outgoing: $0.outgoing.map(rotate)) }
        return result
    }

    /// Test actual surface contact, so cutting away a corner cannot leave a floating tenon.
    func contacts(_ box: Box, size: SIMD3<Double>) -> Bool {
        for face in SolidCSG.extrusion(self, size: size) {
            var points = face.pts
            for axis in 0..<3 {
                var normal = SIMD3<Double>.zero; normal[axis] = 1
                points = Geo.clip(points, p: box.hi, n: normal)
                points = Geo.clip(points, p: box.lo, n: -normal)
            }
            if SolidCSG.face(points, normal: face.n) != nil { return true }
        }
        // An additive box wholly inside the board does not change its surface but is still valid.
        let center = (box.lo + box.hi) / 2
        guard center[thickness] > 0, center[thickness] < size[thickness] else { return false }
        let point = SIMD2(center[u], center[v]), points = contour(size: size)
        var inside = false
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }

    /// Split a segment exactly using de Casteljau, preserving its existing curve.
    mutating func split(after i: Int) {
        let j = (i + 1) % nodes.count, a = nodes[i], d = nodes[j]
        let b = a.outgoing ?? a.point, c = d.incoming ?? d.point
        let ab = (a.point + b) / 2, bc = (b + c) / 2, cd = (c + d.point) / 2
        let abc = (ab + bc) / 2, bcd = (bc + cd) / 2
        let curved = a.outgoing != nil || d.incoming != nil
        nodes[i].outgoing = curved ? ab : nil; nodes[j].incoming = curved ? cd : nil
        nodes.insert(Node(point: (abc + bcd) / 2, incoming: curved ? abc : nil, outgoing: curved ? bcd : nil), at: i + 1)
    }
}
