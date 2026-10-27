import SceneKit
import AppKit

struct Box { var lo: SIMD3<Double>; var hi: SIMD3<Double> }
struct Rect2 { var u0, u1, v0, v1: Double }
struct Quad { var axis: Int; var positive: Bool; var plane: Double; var r: Rect2 }

func vec(_ v: SIMD3<Double>) -> SCNVector3 { SCNVector3(v.x, v.y, v.z) }
func dvec(_ v: SCNVector3) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
func norm(_ v: SIMD3<Double>) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }

/// Boards are axis-aligned boxes with axis-aligned boxes cut out, so "CSG" is just box subtraction.
enum Geo {
    static let eps = 1e-7

    static func subtract(_ a: Box, _ b: Box) -> [Box] {
        for i in 0..<3 where b.hi[i] <= a.lo[i] + eps || b.lo[i] >= a.hi[i] - eps { return [a] }
        var out: [Box] = []
        var rem = a
        for i in 0..<3 {
            if b.lo[i] > rem.lo[i] + eps {
                var piece = rem; piece.hi[i] = b.lo[i]; out.append(piece)
                rem.lo[i] = b.lo[i]
            }
            if b.hi[i] < rem.hi[i] - eps {
                var piece = rem; piece.lo[i] = b.hi[i]; out.append(piece)
                rem.hi[i] = b.hi[i]
            }
        }
        return out
    }

    static func subtract(_ a: Rect2, _ b: Rect2) -> [Rect2] {
        if b.u1 <= a.u0 + eps || b.u0 >= a.u1 - eps || b.v1 <= a.v0 + eps || b.v0 >= a.v1 - eps { return [a] }
        var out: [Rect2] = []
        var r = a
        if b.u0 > r.u0 + eps { out.append(Rect2(u0: r.u0, u1: b.u0, v0: r.v0, v1: r.v1)); r.u0 = b.u0 }
        if b.u1 < r.u1 - eps { out.append(Rect2(u0: b.u1, u1: r.u1, v0: r.v0, v1: r.v1)); r.u1 = b.u1 }
        if b.v0 > r.v0 + eps { out.append(Rect2(u0: r.u0, u1: r.u1, v0: r.v0, v1: b.v0)); r.v0 = b.v0 }
        if b.v1 < r.v1 - eps { out.append(Rect2(u0: r.u0, u1: r.u1, v0: b.v1, v1: r.v1)) }
        return out
    }

    static func solid(_ p: Part) -> [Box] {
        var boxes = [Box(lo: .zero, hi: p.size)]
        for cut in p.cuts where cut.suppressed != true {
            let tool = Box(lo: cut.lo, hi: cut.hi)
            if !cut.additive { boxes = boxes.flatMap { subtract($0, tool) } }
            else {
                var additions = [tool]
                for existing in boxes { additions = additions.flatMap { subtract($0, existing) } }
                boxes += additions
            }
        }
        return boxes
    }

    // MARK: Convex polygon clipping (for miters/bevels)

    /// Keep the part of a convex polygon where n·(x−p) ≤ 0.
    static func clip(_ poly: [SIMD3<Double>], p: SIMD3<Double>, n: SIMD3<Double>) -> [SIMD3<Double>] {
        func side(_ x: SIMD3<Double>) -> Double { n.x * (x.x - p.x) + n.y * (x.y - p.y) + n.z * (x.z - p.z) }
        var out: [SIMD3<Double>] = []
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let da = side(a), db = side(b)
            if da <= eps { out.append(a) }
            if (da < -eps && db > eps) || (da > eps && db < -eps) {
                out.append(a + (b - a) * (da / (da - db)))
            }
        }
        return out
    }

    struct Poly { var pts: [SIMD3<Double>]; var n: SIMD3<Double>; var source: UUID? = nil }

    /// All boundary polygons of a part, trims applied.
    static func polys(for p: Part) -> [Poly] {
        if p.featureOrder != nil || !(p.patterns ?? []).isEmpty { return FeatureReplay.polygons(p) }
        return p.profile == nil && p.mesh == nil && (p.operations ?? []).isEmpty && !p.cuts.contains(where: { $0.relief != nil || $0.allowance != nil || $0.planes != nil }) && !p.hasPartialEdges
            ? polys(boxes: solid(p), planes: p.clipPlanes) : SolidCSG.polys(for: p)
    }

    static func polys(boxes: [Box], planes: [(p: SIMD3<Double>, n: SIMD3<Double>)]) -> [Poly] {
        var out: [Poly] = []
        for q in quads(boxes) {
            var pts = corners(q)
            for pl in planes where pts.count >= 3 { pts = clip(pts, p: pl.p, n: pl.n) }
            guard pts.count >= 3 else { continue }
            var n = SIMD3<Double>.zero
            n[q.axis] = q.positive ? 1 : -1
            out.append(Poly(pts: pts, n: n))
        }
        for (k, pl) in planes.enumerated() {
            // A big square on the cut plane, trimmed to each solid piece to form the cap.
            let ref: SIMD3<Double> = abs(pl.n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            let u = simdNormalize(cross(pl.n, ref)), v = cross(pl.n, u)
            var reach: Double = 1
            for box in boxes { reach = max(reach, norm(box.lo - pl.p), norm(box.hi - pl.p)) }
            let big: Double = reach * 4
            let du: SIMD3<Double> = u * big, dv: SIMD3<Double> = v * big
            let square: [SIMD3<Double>] = [pl.p - du - dv, pl.p + du - dv, pl.p + du + dv, pl.p - du + dv]
            for b in boxes {
                var pts = square
                for a in 0..<3 {
                    var n = SIMD3<Double>.zero
                    n[a] = 1
                    pts = clip(pts, p: b.hi, n: n)
                    n[a] = -1
                    if pts.count >= 3 { pts = clip(pts, p: b.lo, n: n) }
                }
                for (j, other) in planes.enumerated() where j != k && pts.count >= 3 { pts = clip(pts, p: other.p, n: other.n) }
                if pts.count >= 3 { out.append(Poly(pts: pts, n: pl.n)) }
            }
        }
        return out
    }

    /// Exposed faces only: faces shared between two pieces are removed.
    static func quads(_ boxes: [Box]) -> [Quad] {
        var out: [Quad] = []
        for (i, b) in boxes.enumerated() {
            for a in 0..<3 {
                let u = (a + 1) % 3, v = (a + 2) % 3
                for positive in [true, false] {
                    let plane = positive ? b.hi[a] : b.lo[a]
                    var rects = [Rect2(u0: b.lo[u], u1: b.hi[u], v0: b.lo[v], v1: b.hi[v])]
                    for (j, o) in boxes.enumerated() where j != i {
                        let opp = positive ? o.lo[a] : o.hi[a]
                        guard abs(opp - plane) < eps else { continue }
                        let cover = Rect2(u0: o.lo[u], u1: o.hi[u], v0: o.lo[v], v1: o.hi[v])
                        rects = rects.flatMap { subtract($0, cover) }
                        if rects.isEmpty { break }
                    }
                    for r in rects where r.u1 - r.u0 > eps && r.v1 - r.v0 > eps {
                        out.append(Quad(axis: a, positive: positive, plane: plane, r: r))
                    }
                }
            }
        }
        return out
    }

    static func corners(_ q: Quad) -> [SIMD3<Double>] {
        let a = q.axis, u = (a + 1) % 3, v = (a + 2) % 3
        var uv = [(q.r.u0, q.r.v0), (q.r.u1, q.r.v0), (q.r.u1, q.r.v1), (q.r.u0, q.r.v1)]
        if !q.positive { uv.reverse() }
        return uv.map { cu, cv in
            var p = SIMD3<Double>.zero
            p[a] = q.plane; p[u] = cu; p[v] = cv
            return p
        }
    }

    static func geometry(for p: Part, polygons: [Poly]? = nil) -> SCNGeometry {
        var verts: [SCNVector3] = [], norms: [SCNVector3] = [], uvs: [CGPoint] = []
        var idx: [UInt32] = []
        let grain = p.grainAxis
        for poly in polygons ?? polys(for: p) {
            let n = [abs(poly.n.x), abs(poly.n.y), abs(poly.n.z)]
            let a = n.indices.max { n[$0] < n[$1] }!
            let u = (a + 1) % 3, v = (a + 2) % 3
            let base = UInt32(verts.count)
            for pt in poly.pts {
                verts.append(vec(pt)); norms.append(vec(poly.n))
                // Grain runs along texture-u; end grain just gets the same texture.
                let (tu, tv) = grain == v ? (pt[v], pt[u]) : (pt[u], pt[v])
                uvs.append(CGPoint(x: tu / 24, y: tv / 24))
            }
            for i in 1..<(poly.pts.count - 1) { idx += [base, base + UInt32(i), base + UInt32(i + 1)] }
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts),
                                      SCNGeometrySource(normals: norms),
                                      SCNGeometrySource(textureCoordinates: uvs)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = WoodTexture.image(for: p.species)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.isDoubleSided = false
        g.materials = [m]
        return g
    }

    private static let edgePairs: [(Int, Int)] = [
        (0, 1), (1, 3), (3, 2), (2, 0), (4, 5), (5, 7), (7, 6), (6, 4), (0, 4), (1, 5), (2, 6), (3, 7),
    ]

    /// Outline of the board plus the edges of every cut, nudged outward so lines don't z-fight faces.
    static func edgeGeometry(for p: Part, polygons: [Poly]? = nil) -> SCNGeometry {
        var verts: [SCNVector3] = []
        var idx: [UInt32] = []
        let c = p.size / 2
        func nudge(_ pt: SIMD3<Double>) -> SCNVector3 { vec(c + (pt - c) * 1.0005) }
        if p.profile != nil || p.mesh != nil || !(p.operations ?? []).isEmpty || !(p.patterns ?? []).isEmpty || p.featureOrder != nil || p.cuts.contains(where: { $0.relief != nil || $0.allowance != nil || $0.planes != nil }) || p.hasEdgeProfiles {
            // Hide coplanar triangulation seams and the tiny facets along a smooth curve.
            struct EdgeKey: Hashable { var a: SIMD3<Double>; var b: SIMD3<Double> }
            var edges: [EdgeKey: (a: SIMD3<Double>, b: SIMD3<Double>, normals: [SIMD3<Double>])] = [:]
            func rounded(_ pt: SIMD3<Double>) -> SIMD3<Double> {
                SIMD3((pt.x * 1e6).rounded(), (pt.y * 1e6).rounded(), (pt.z * 1e6).rounded())
            }
            for poly in polygons ?? polys(for:p) {
                for i in poly.pts.indices {
                    let a = poly.pts[i], b = poly.pts[(i + 1) % poly.pts.count]
                    let ra = rounded(a), rb = rounded(b)
                    let forward = ra.x != rb.x ? ra.x < rb.x : (ra.y != rb.y ? ra.y < rb.y : ra.z < rb.z)
                    let key = EdgeKey(a: forward ? ra : rb, b: forward ? rb : ra)
                    if edges[key] != nil { edges[key]!.normals.append(poly.n) }
                    else { edges[key] = (a, b, [poly.n]) }
                }
            }
            for edge in edges.values {
                let crease = edge.normals.dropFirst().contains { simd_dot($0, edge.normals[0]) < 0.95 }
                if edge.normals.count == 1 || crease {
                    let base = UInt32(verts.count)
                    verts += [nudge(edge.a), nudge(edge.b)]; idx += [base, base + 1]
                }
            }
        } else if p.trims.isEmpty {
            func addBox(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) {
                let base = UInt32(verts.count)
                for i in 0..<8 {
                    verts.append(nudge(SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)))
                }
                for (a, b) in edgePairs { idx += [base + UInt32(a), base + UInt32(b)] }
            }
            addBox(.zero, p.size)
            for cut in p.cuts {
                let lo = cut.additive ? cut.lo : pointwiseMax(cut.lo, .zero)
                let hi = cut.additive ? cut.hi : pointwiseMin(cut.hi, p.size)
                if hi.x > lo.x && hi.y > lo.y && hi.z > lo.z { addBox(lo, hi) }
            }
        } else {
            for poly in polygons ?? polys(for:p) {
                let base = UInt32(verts.count)
                verts += poly.pts.map(nudge)
                for i in poly.pts.indices { idx += [base + UInt32(i), base + UInt32((i + 1) % poly.pts.count)] }
            }
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        g.materials = [Geo.lineMaterial(.black)]
        return g
    }

    static func lineMaterial(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }
}
