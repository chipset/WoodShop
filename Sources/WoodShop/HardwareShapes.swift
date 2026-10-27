import Foundation
import simd

/// Recognizable stand-in shapes for hardware stock: hinges, slides, pulls, knobs, braces, screws and pins.
/// They are display models sized to the stock item's bounding box; they are not manufacturer geometry.
enum HardwareShapes {
    /// A closed mesh for the named stock item, normalized to the part's box, or nil for unknown items.
    static func mesh(stock name: String, size: SIMD3<Double>) -> MeshSolid? {
        let L = size.x, T = size.y, W = size.z
        guard L > 0, T > 0, W > 0 else { return nil }
        var solids: [[Geo.Poly]] = []
        func box(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) {
            guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else { return }
            solids.append(prism(rect: (lo, hi), axis: 1))
        }
        /// Cylinder along `axis`, centred at the given point on the other two axes.
        func cylinder(axis: Int, center: SIMD3<Double>, radius: Double, from: Double, to: Double, sides: Int = 20) {
            guard radius > 0, to > from else { return }
            let u = (axis + 1) % 3, v = (axis + 2) % 3
            let ring = MeshTools.circle(center: SIMD2(center[u], center[v]), radius: radius, segments: sides)
            solids.append(MeshTools.loft(ring, axis: axis, top: to, bottom: from))
        }
        func polygon(_ points: [SIMD2<Double>], axis: Int, from: Double, to: Double) {
            solids.append(MeshTools.loft(points, axis: axis, top: to, bottom: from))
        }

        if name.hasPrefix("Hinge") {
            // Two leaves meeting at a knuckled barrel along the length.
            let barrel = min(T, W * 0.25), leaf = T * 0.55, cz = W / 2
            box(SIMD3(0, 0, 0), SIMD3(L, leaf, cz - barrel / 2))
            box(SIMD3(0, 0, cz + barrel / 2), SIMD3(L, leaf, W))
            let knuckles = 5, gap = L * 0.008, seg = L / Double(knuckles)
            for k in 0..<knuckles {
                cylinder(axis: 0, center: SIMD3(0, T / 2, cz), radius: barrel / 2, from: Double(k) * seg + gap, to: Double(k + 1) * seg - gap)
            }
        } else if name.hasPrefix("Drawer slide") {
            // Cabinet member, drawer member and a ball carrier between them.
            box(SIMD3(0, 0, 0), SIMD3(L, T, W * 0.42))
            box(SIMD3(L * 0.06, 0, W * 0.58), SIMD3(L, T, W))
            box(SIMD3(L * 0.12, T * 0.25, W * 0.42), SIMD3(L * 0.88, T * 0.75, W * 0.58))
        } else if name.hasPrefix("Bar pull") {
            // A bar on two posts; the posts project along the thickness.
            let post = min(W * 0.55, L * 0.08), barLow = T * 0.62
            box(SIMD3(L * 0.07, 0, (W - post) / 2), SIMD3(L * 0.07 + post, barLow, (W + post) / 2))
            box(SIMD3(L * 0.93 - post, 0, (W - post) / 2), SIMD3(L * 0.93, barLow, (W + post) / 2))
            box(SIMD3(0, barLow, W * 0.1), SIMD3(L, T, W * 0.9))
        } else if name.hasPrefix("Knob") {
            let c = SIMD3(L / 2, 0, W / 2)
            cylinder(axis: 1, center: c, radius: min(L, W) * 0.16, from: 0, to: T * 0.3, sides: 16)
            cylinder(axis: 1, center: c, radius: min(L, W) * 0.5, from: T * 0.3, to: T, sides: 32)
        } else if name.hasPrefix("Corner brace") {
            // A flat plate with cut corners and three screw heads.
            let c = min(W * 0.3, L * 0.1), plate = T * 0.65
            // Profile in (Z, X) for an extrusion along Y.
            polygon([SIMD2(c, 0), SIMD2(W - c, 0), SIMD2(W, c), SIMD2(W, L - c), SIMD2(W - c, L), SIMD2(c, L), SIMD2(0, L - c), SIMD2(0, c)],
                    axis: 1, from: 0, to: plate)
            for x in [L * 0.15, L * 0.5, L * 0.85] {
                cylinder(axis: 1, center: SIMD3(x, 0, W / 2), radius: min(W * 0.2, L * 0.06), from: plate, to: T, sides: 14)
            }
        } else if name.hasPrefix("Screw") {
            let c = SIMD3(0, T / 2, W / 2), r = min(T, W) / 2
            cylinder(axis: 0, center: c, radius: r * 0.55, from: 0, to: L * 0.9, sides: 12)
            cylinder(axis: 0, center: c, radius: r, from: L * 0.9, to: L, sides: 16)
        } else if name.hasPrefix("Shelf pin") {
            let c = SIMD3(0, T / 2, W / 2), r = min(T, W) / 2
            cylinder(axis: 0, center: c, radius: r * 0.6, from: 0, to: L * 0.7, sides: 12)
            cylinder(axis: 0, center: c, radius: r, from: L * 0.7, to: L * 0.8, sides: 16)
            cylinder(axis: 0, center: c, radius: r * 0.6, from: L * 0.8, to: L, sides: 12)
        } else { return nil }

        let faces = solids.flatMap { $0 }.map { poly in poly.pts.map { SIMD3($0.x / L, $0.y / T, $0.z / W) } }
        guard !faces.isEmpty else { return nil }
        return MeshSolid(faces: faces.map { $0.map { SIMD3(min(max($0.x, 0), 1), min(max($0.y, 0), 1), min(max($0.z, 0), 1)) } })
    }

    /// Axis-aligned block as a loft of its rectangle.
    private static func prism(rect: (lo: SIMD3<Double>, hi: SIMD3<Double>), axis: Int) -> [Geo.Poly] {
        let u = (axis + 1) % 3, v = (axis + 2) % 3
        let r = [SIMD2(rect.lo[u], rect.lo[v]), SIMD2(rect.hi[u], rect.lo[v]), SIMD2(rect.hi[u], rect.hi[v]), SIMD2(rect.lo[u], rect.hi[v])]
        return MeshTools.loft(r, axis: axis, top: rect.hi[axis], bottom: rect.lo[axis])
    }
}
