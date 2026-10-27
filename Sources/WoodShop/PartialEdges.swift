import Foundation
import simd

extension Part {
    var hasPartialEdges: Bool { (edges ?? []).contains { $0.isPartial } }

    /// Closed tool solids for chamfers and roundovers that stop short of the ends of their edge.
    /// Built from the board's current size, so they follow resizing and rotation.
    var partialEdgeTools: [Geo.Poly] {
        var out: [Geo.Poly] = []
        for e in edges ?? [] where e.isPartial {
            guard e.axis1 != e.axis2, e.size > 0, e.size.isFinite else { continue }
            let m = 3 - e.axis1 - e.axis2
            let lo = max(0, e.from ?? 0), hi = min(size[m], e.to ?? size[m])
            guard hi - lo > 1e-6 else { continue }
            func unit(_ axis: Int, _ pos: Bool) -> SIMD3<Double> { var v = SIMD3<Double>.zero; v[axis] = pos ? 1 : -1; return v }
            let e1 = unit(e.axis1, e.pos1), e2 = unit(e.axis2, e.pos2)
            var corner = SIMD3<Double>.zero
            for (ax, pos) in [(e.axis1, e.pos1), (e.axis2, e.pos2)] { corner[ax] = pos ? size[ax] : 0 }
            let r = e.size, eps = 0.01
            // Cross-section of the material removed, reaching a hair outside both faces.
            var ring: [SIMD3<Double>] = [corner + (e1 + e2) * eps, corner - e1 * r + e2 * eps]
            if e.kind == .chamfer {
                ring += [corner - e1 * r, corner - e2 * r]
            } else {
                let c = corner - (e1 + e2) * r
                let n = r > 1 ? 14 : 9
                for k in 0...n {
                    let phi = (.pi / 2) * (1 - Double(k) / Double(n))
                    ring.append(c + (e1 * cos(phi) + e2 * sin(phi)) * r)
                }
            }
            ring.append(corner - e2 * r + e1 * eps)
            let u = (m + 1) % 3, v = (m + 2) % 3
            let flat = ring.map { SIMD2($0[u], $0[v]) }
            let top = hi >= size[m] - 1e-9 ? hi + eps : hi
            let bottom = lo <= 1e-9 ? lo - eps : lo
            out += MeshTools.loft(flat, axis: m, top: top, bottom: bottom)
        }
        return out
    }
}
