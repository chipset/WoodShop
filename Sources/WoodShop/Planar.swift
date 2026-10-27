import Foundation

/// Boundary extraction for a union of simple, counterclockwise polygons.
/// Segment splitting preserves concave tenon outlines without taking a convex hull.
enum Planar {
    private static let eps = 1e-7
    static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
    static func signedArea(_ points: [SIMD2<Double>]) -> Double {
        points.indices.reduce(0) { $0 + cross(points[$1], points[($1 + 1) % points.count]) } / 2
    }

    static func isSimple(_ points: [SIMD2<Double>]) -> Bool {
        guard points.count >= 3 else { return false }
        func onSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            abs(cross(b - a, p - a)) < eps && p.x >= min(a.x, b.x) - eps && p.x <= max(a.x, b.x) + eps
                && p.y >= min(a.y, b.y) - eps && p.y <= max(a.y, b.y) + eps
        }
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            guard abs(a.x - b.x) + abs(a.y - b.y) > eps else { return false }
            for j in (i + 1)..<points.count where j != (i + 1) % points.count && (j + 1) % points.count != i {
                let c = points[j], d = points[(j + 1) % points.count]
                let abC = cross(b - a, c - a), abD = cross(b - a, d - a)
                let cdA = cross(d - c, a - c), cdB = cross(d - c, b - c)
                if (abC > eps && abD < -eps || abC < -eps && abD > eps)
                    && (cdA > eps && cdB < -eps || cdA < -eps && cdB > eps) { return false }
                if onSegment(c, a, b) || onSegment(d, a, b) || onSegment(a, c, d) || onSegment(b, c, d) { return false }
            }
        }
        return true
    }

    /// Ear clipping keeps concave profiles concave, with consistently wound convex faces.
    static func triangulate(_ input: [SIMD2<Double>]) -> [[SIMD2<Double>]] {
        var points = signedArea(input) < 0 ? Array(input.reversed()) : input
        var triangles: [[SIMD2<Double>]] = []
        while points.count > 3 {
            var found = false
            for i in points.indices {
                let prev = (i + points.count - 1) % points.count, next = (i + 1) % points.count
                let a = points[prev], b = points[i], c = points[next]
                let turn = cross(b - a, c - b)
                if abs(turn) < 1e-12 { points.remove(at: i); found = true; break }
                guard turn > 0 else { continue }
                let contains = points.indices.contains { j in
                    guard j != prev && j != i && j != next else { return false }
                    let p = points[j]
                    return cross(b - a, p - a) >= -1e-12 && cross(c - b, p - b) >= -1e-12 && cross(a - c, p - c) >= -1e-12
                }
                if !contains { triangles.append([a, b, c]); points.remove(at: i); found = true; break }
            }
            guard found else { return [] }
        }
        if points.count == 3 { triangles.append(points) }
        return triangles
    }

    static func hull(_ input: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let points = Array(Set(input)).sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard points.count > 2 else { return points }
        func half(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
            var result: [SIMD2<Double>] = []
            for p in points {
                while result.count >= 2 && cross(result.last! - result[result.count - 2], p - result.last!) <= eps { result.removeLast() }
                result.append(p)
            }
            return result
        }
        return Array(half(points).dropLast()) + Array(half(Array(points.reversed())).dropLast())
    }
    static func union(_ polygons: [[SIMD2<Double>]]) -> [[SIMD2<Double>]] {
        let polys = polygons.filter { $0.count >= 3 }
        func inside(_ point: SIMD2<Double>) -> Bool {
            polys.contains { poly in
                var result = false
                for i in poly.indices {
                    let a = poly[i], b = poly[(i + 1) % poly.count]
                    if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
                }
                return result
            }
        }
        struct Segment { var a: SIMD2<Double>; var b: SIMD2<Double> }
        let all = polys.flatMap { poly in poly.indices.map { Segment(a: poly[$0], b: poly[($0 + 1) % poly.count]) } }
        var boundary: [Segment] = []
        func norm2(_ v: SIMD2<Double>) -> Double { v.x * v.x + v.y * v.y }
        for segment in all {
            let d = segment.b - segment.a, length2 = norm2(d)
            guard length2 > eps * eps else { continue }
            var splits = [0.0, 1.0]
            for other in all {
                let e = other.b - other.a, denominator = cross(d, e)
                if abs(denominator) > eps {
                    let t = cross(other.a - segment.a, e) / denominator
                    let u = cross(other.a - segment.a, d) / denominator
                    if t > eps, t < 1 - eps, u >= -eps, u <= 1 + eps { splits.append(t) }
                } else if abs(cross(other.a - segment.a, d)) < eps {
                    for pt in [other.a, other.b] {
                        let delta = pt - segment.a
                        let t = (delta.x * d.x + delta.y * d.y) / length2
                        if t > eps, t < 1 - eps { splits.append(t) }
                    }
                }
            }
            splits.sort()
            for i in 0..<(splits.count - 1) where splits[i + 1] - splits[i] > eps {
                let a = segment.a + d * splits[i], b = segment.a + d * splits[i + 1]
                let middle = (a + b) / 2
                let normal = SIMD2(-d.y, d.x) / sqrt(length2) * (eps * 4)
                let left = inside(middle + normal), right = inside(middle - normal)
                if left != right { boundary.append(left ? Segment(a: a, b: b) : Segment(a: b, b: a)) }
            }
        }
        func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool { norm2(a - b) < eps * eps * 4 }
        var unique: [Segment] = []
        for edge in boundary where !unique.contains(where: { near($0.a, edge.a) && near($0.b, edge.b) }) { unique.append(edge) }
        var contours: [[SIMD2<Double>]] = []
        while !unique.isEmpty {
            let first = unique.removeFirst()
            var contour = [first.a], end = first.b
            var closed = false
            while contour.count <= boundary.count + 1 {
                if near(end, contour[0]) { closed = true; break }
                contour.append(end)
                guard let index = unique.firstIndex(where: { near($0.a, end) }) else { break }
                end = unique.remove(at: index).b
            }
            if closed, contour.count >= 3 { contours.append(contour) }
        }
        return contours
    }
}
