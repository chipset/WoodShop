import Foundation

/// Generators for angled bores that a rectangular void cannot express. Everything is a `Cut` with clip planes
/// in board-local coordinates (the cut is its box intersected with those half-spaces).
enum JoineryGen {
    // MARK: Round holes

    /// Circumscribed polygon so the bore is never smaller than the nominal diameter.
    static func cylinder(kind: String, axisPoint: SIMD3<Double>, axis d: SIMD3<Double>, diameter: Double,
                         from t0: Double, to t1: Double, faceAxis: Int, facePositive: Bool, runAxis: Int, sides: Int? = nil) -> Cut {
        let n = sides ?? (diameter > 2 ? 24 : 16)
        let dir = simdNormalize(d)
        let ref: SIMD3<Double> = abs(dir.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simdNormalize(cross(dir, ref)), v = cross(dir, u)
        let r = diameter / 2, rc = r / cos(.pi / Double(n))
        var planes: [Plane] = []
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for k in 0..<n {
            let th = 2 * .pi * Double(k) / Double(n)
            let mid = th + .pi / Double(n)
            let nn = u * cos(mid) + v * sin(mid)
            planes.append(Plane(p: axisPoint + nn * r, n: nn))
        }
        // Polygon vertices sit between adjacent tangent planes, at angles k·2π/n.
        for k in 0..<n {
            let th = 2 * .pi * Double(k) / Double(n)
            let off = u * cos(th) * rc + v * sin(th) * rc
            for t in [t0, t1] {
                let pt = axisPoint + dir * t + off
                lo = pointwiseMin(lo, pt); hi = pointwiseMax(hi, pt)
            }
        }
        planes.append(Plane(p: axisPoint + dir * t1, n: dir))
        planes.append(Plane(p: axisPoint + dir * t0, n: -dir))
        return Cut(kind: kind, lo: lo, hi: hi, faceAxis: faceAxis, facePositive: facePositive, runAxis: runAxis, planes: planes)
    }

    /// A pocket hole: a shallow-angle bore from a face toward the nearer end along `run`.
    static func pocketHole(part: Part, face: FaceRef, run: Int, towardPositiveEnd: Bool, entry: SIMD2<Double>,
                           diameter: Double = 0.375, angle: Double = 15, length: Double = 1.5) -> Cut {
        let a = face.axis
        let other = [(a + 1) % 3, (a + 2) % 3].first { $0 != run }!
        var p = SIMD3<Double>.zero
        p[a] = face.positive ? part.size[a] : 0
        p[run] = entry.x
        p[other] = entry.y
        let th = angle * .pi / 180
        var d = SIMD3<Double>.zero
        d[a] = face.positive ? -sin(th) : sin(th)
        d[run] = (towardPositiveEnd ? 1 : -1) * cos(th)
        // Back the start off outside the face so the opening is complete.
        let back = diameter / sin(th) / 2 + 0.1
        return cylinder(kind: "Pocket Hole", axisPoint: p, axis: d, diameter: diameter, from: -back, to: length,
                        faceAxis: a, facePositive: face.positive, runAxis: run)
    }
}
