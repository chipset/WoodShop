import SceneKit
import simd

struct InferencePoint {
    var point: SIMD3<Double>
    var label: String
}
enum Inference {
    static func candidates(parts: [Part], guides: [ConstructionGuide], polygons: ((Part) -> [Geo.Poly])? = nil) -> [InferencePoint] {
        var points: [InferencePoint] = []
        points.reserveCapacity(parts.count * 16 + guides.count)
        for part in parts {
            let polygons = polygons?(part) ?? Geo.polys(for:part)
            var seen: Set<SIMD3<Double>> = []
            seen.reserveCapacity(16)
            let rotated = part.isRotated
            let rotation = rotated ? part.rotMatrix : matrix_identity_double3x3
            let offset = rotated ? part.center - rotation * (part.size / 2) : part.origin
            for polygon in polygons {
                for i in polygon.pts.indices {
                    let aLocal = polygon.pts[i], bLocal = polygon.pts[(i + 1) % polygon.pts.count]
                    let a = rotated ? offset + rotation * aLocal : offset + aLocal
                    let b = rotated ? offset + rotation * bLocal : offset + bLocal
                    for (p, label) in [(a, "Endpoint"), ((a + b) / 2, "Midpoint")] {
                        let key = SIMD3((p.x * 1e6).rounded(), (p.y * 1e6).rounded(), (p.z * 1e6).rounded())
                        if seen.insert(key).inserted { points.append(InferencePoint(point: p, label: label)) }
                    }
                }
            }
        }
        for (i, guide) in guides.enumerated() {
            points.append(InferencePoint(point: guide.point, label: "Guide origin"))
            for other in guides.dropFirst(i + 1) {
                let n = cross(guide.direction, other.direction), denom = simd_length_squared(n)
                if denom > 1e-9 {
                    let t = simd_dot(cross(other.point - guide.point, other.direction), n) / denom
                    let p = guide.point + guide.direction * t
                    if abs(simd_dot(p - other.point, n)) < 1e-6 { points.append(InferencePoint(point: p, label: "Guide intersection")) }
                }
            }
        }
        return points
    }
    static func nearest(_ screen: SIMD2<Double>, candidates: [InferencePoint], project: (SIMD3<Double>) -> SIMD2<Double>, tolerance: Double = 9) -> InferencePoint? {
        var best = tolerance * tolerance
        var found: InferencePoint?
        for candidate in candidates {
            let delta = project(candidate.point) - screen
            let distance = simd_length_squared(delta)
            if distance < best || (found == nil && distance == best) { best = distance; found = candidate }
        }
        return found
    }
    static func nearest(_ screen: SIMD2<Double>, candidates: [InferencePoint], projected: [SIMD2<Double>], tolerance: Double = 9) -> InferencePoint? {
        guard candidates.count == projected.count else { return nil }
        var best = tolerance * tolerance
        var found: Int?
        for i in candidates.indices {
            let delta = projected[i] - screen
            let distance = simd_length_squared(delta)
            if distance < best || (found == nil && distance == best) { best = distance; found = i }
        }
        return found.map { candidates[$0] }
    }
}
extension Geo {
    static func sectionPolygons(_ part: Part, section: SectionPlane, polygons: [Poly]? = nil) -> [Poly] {
        var normal = SIMD3<Double>.zero; normal[section.axis] = section.keepPositive ? -1 : 1
        var point = SIMD3<Double>.zero; point[section.axis] = section.value
        let localNormal = part.rotMatrix.transpose * normal
        let localPoint = part.size / 2 + part.rotMatrix.transpose * (point - part.center)
        let reach = max(1000, norm(part.size) * 4)
        let bounds = Box(lo: SIMD3(repeating: -reach), hi: SIMD3(repeating: reach))
        let clipper = polys(boxes: [bounds], planes: [(localPoint, localNormal)])
        return SolidCSG.intersection(polygons ?? polys(for: part), clipper)
    }
}
extension SceneController {
    func saveScene(_ name: String) {
        doc.transaction {
            doc.studio.scenes.append(SavedScene(name: name, target: target, distance: distance, yaw: yaw, pitch: pitch, ortho: ortho,
                visible: doc.parts.filter(doc.isVisible).map(\.id), section: doc.studio.section))
        }
    }
    func restoreScene(_ saved: SavedScene) {
        doc.transaction {
            doc.isolateSelection = false
            for i in doc.parts.indices { doc.parts[i].hidden = !saved.visible.contains(doc.parts[i].id) }
            doc.studio.section = saved.section
        }
        target = saved.target; distance = saved.distance; yaw = saved.yaw; pitch = saved.pitch; ortho = saved.ortho; updateCamera()
    }
}
