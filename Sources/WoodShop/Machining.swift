import Foundation
import simd

enum ReliefStyle: String, Codable, CaseIterable, Identifiable {
    case none = "None", dogbone = "Dogbone", tboneX = "T-bone along U", tboneY = "T-bone along V"
    var id: String { rawValue }
}
struct CornerRelief: Codable, Equatable {
    var style = ReliefStyle.dogbone
    var diameter = 0.25
    var corners = [true, true, true, true]
}

struct MachiningOperation: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var axis: Int
    var positive: Bool
    var depth: Double
    var contour: [SIMD2<Double>]
    /// Bottom/top contour scale for tapered sockets and countersinks.
    var bottomScale = 1.0
    var kind = "Pocket"
    var bottomStretch: SIMD2<Double>? = nil
    var suppressed: Bool? = nil
    var patternID: UUID? = nil
    var sketch: FaceSketch? = nil
    var islands: [[SIMD2<Double>]]? = nil
    var u: Int { (axis + 1) % 3 }
    var v: Int { (axis + 2) % 3 }
    func polygons(size: SIMD3<Double>) -> [Geo.Poly] {
        let top = positive ? size[axis] : 0
        let bottom = top + (positive ? -depth : depth)
        var result = MeshTools.loft(contour, axis: axis, top: top, bottom: bottom, bottomScale: bottomScale, bottomStretch: bottomStretch)
        for island in islands ?? [] { result = SolidCSG.subtract(result,MeshTools.loft(island,axis:axis,top:top,bottom:bottom)) }
        return result
    }
    func validation(size: SIMD3<Double>, checkStock: Bool = true) -> String? {
        if let sketch,let message = sketch.validation() { return message }
        guard (0..<3).contains(axis), depth.isFinite, depth > 0, (!checkStock || depth <= size[axis] + 1e-6),
              bottomScale.isFinite, bottomScale > 0, bottomScale <= 10,
              (3...512).contains(contour.count), contour.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              Planar.isSimple(contour), abs(Planar.signedArea(contour)) > 1e-8 else { return "Invalid machining contour, axis, or depth." }
        if let stretch = bottomStretch, !stretch.x.isFinite || !stretch.y.isFinite || stretch.x <= 0 || stretch.y <= 0 || stretch.x > 10 || stretch.y > 10 { return "Invalid operation taper." }
        guard (islands ?? []).count<=16,(islands ?? []).allSatisfy({ PocketRegion.validIsland($0,inside:contour) }) else { return "Pocket islands must be simple closed contours strictly inside the pocket." }
        let islands = islands ?? []
        for i in islands.indices { for j in islands.indices where j>i { if !PocketRegion.disjoint(islands[i],islands[j]) { return "Pocket islands must not overlap or touch." } } }
        guard islands.isEmpty || (bottomScale == 1 && bottomStretch == nil) else { return "Islands require straight pocket walls." }
        guard checkStock else { return nil }
        let center = contour.reduce(.zero, +) / Double(contour.count)
        for point in contour + contour.map({ center + ($0 - center) * (bottomStretch ?? SIMD2(repeating: bottomScale)) }) {
            guard point.x >= -1e-7, point.y >= -1e-7, point.x <= size[u] + 1e-7, point.y <= size[v] + 1e-7 else { return "Machining must remain inside the stock face." }
        }
        return nil
    }
}

extension Cut {
    func machiningContour(part: Part) -> [SIMD2<Double>] {
        let axis = faceAxis ?? part.materialAxes.t, u = (axis + 1) % 3, v = (axis + 2) % 3
        let gap = allowance ?? 0
        let a = SIMD2(lo[u] - gap / 2, lo[v] - gap / 2), b = SIMD2(hi[u] + gap / 2, hi[v] + gap / 2)
        let rectangle = [a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y)]
        guard let relief, relief.style != .none else { return rectangle }
        let r = relief.diameter / 2
        var shapes = [rectangle]
        for i in 0..<4 where relief.corners[i] {
            let sign = SIMD2(i == 0 || i == 3 ? 1.0 : -1, i < 2 ? 1.0 : -1)
            let shift: SIMD2<Double>
            switch relief.style {
            case .dogbone: shift = sign * (r / sqrt(2))
            case .tboneX: shift = SIMD2(sign.x * r, 0)
            case .tboneY: shift = SIMD2(0, sign.y * r)
            case .none: shift = .zero
            }
            shapes.append(MeshTools.circle(center: rectangle[i] + shift, radius: r))
        }
        return Planar.union(shapes).max { abs(Planar.signedArea($0)) < abs(Planar.signedArea($1)) } ?? rectangle
    }
    func machiningPolygons(part: Part) -> [Geo.Poly] {
        let a = faceAxis ?? part.materialAxes.t
        return MeshTools.loft(machiningContour(part: part), axis: a, top: hi[a], bottom: lo[a])
    }
}

struct MeshSolid: Codable, Equatable {
    /// Normalized local polygons; resizing a part preserves its surface shape.
    var faces: [[SIMD3<Double>]]
    func polygons(size: SIMD3<Double>) -> [Geo.Poly] {
        faces.compactMap { face in
            let points = face.map { $0 * size }
            guard points.count >= 3 else { return nil }
            let area = points.indices.reduce(SIMD3<Double>.zero) { $0 + cross(points[$1]-points[0],points[($1+1)%points.count]-points[0]) }
            return SolidCSG.face(points,normal:simdNormalize(area))
        }
    }
}

enum MeshTools {
    static func circle(center: SIMD2<Double>, radius: Double, segments: Int = 48) -> [SIMD2<Double>] {
        (0..<segments).map { i in let a = 2 * Double.pi * Double(i) / Double(segments); return center + radius * SIMD2(cos(a), sin(a)) }
    }
    static func loft(_ input: [SIMD2<Double>], axis: Int, top: Double, bottom: Double, bottomScale: Double = 1, bottomStretch: SIMD2<Double>? = nil) -> [Geo.Poly] {
        let points = Planar.signedArea(input) < 0 ? Array(input.reversed()) : input
        guard points.count >= 3 else { return [] }
        let center = points.reduce(.zero, +) / Double(points.count)
        let stretch = bottomStretch ?? SIMD2(repeating: bottomScale)
        let u = (axis + 1) % 3, v = (axis + 2) % 3
        func local(_ p: SIMD2<Double>, _ height: Double) -> SIMD3<Double> { var out = SIMD3<Double>.zero; out[u] = p.x; out[v] = p.y; out[axis] = height; return out }
        var normal = SIMD3<Double>.zero; normal[axis] = top >= bottom ? 1 : -1
        var result: [Geo.Poly] = []
        for triangle in Planar.triangulate(points) {
            if let f = SolidCSG.face(triangle.map { local($0, top) }, normal: normal) { result.append(f) }
            if let f = SolidCSG.face(triangle.map { local(center + ($0 - center) * stretch, bottom) }, normal: -normal) { result.append(f) }
        }
        for i in points.indices {
            let j = (i + 1) % points.count
            let a = local(points[i], top), b = local(points[j], top)
            let c = local(center + (points[j] - center) * stretch, bottom)
            let d = local(center + (points[i] - center) * stretch, bottom)
            let outward = simdNormalize(cross(b - a, c - a)) * (top >= bottom ? -1 : 1)
            if let f = SolidCSG.face([a, b, c, d], normal: outward) { result.append(f) }
        }
        return result
    }
    static func part(polygons: [Geo.Poly], name: String, species: Species = .oak) throws -> Part {
        let points = polygons.flatMap(\.pts)
        guard let first = points.first, points.allSatisfy(ModelValidation.finite) else { throw ModelValidation.Failure(message: "The solid is empty or invalid.") }
        let lo = points.reduce(first, pointwiseMin), hi = points.reduce(first, pointwiseMax)
        let size = hi - lo
        guard (0..<3).allSatisfy({ size[$0] >= 1 / 32 }) else { throw ModelValidation.Failure(message: "A solid must have thickness on every axis.") }
        var p = Part(name: name, origin: lo, size: size, species: species)
        p.mesh = MeshSolid(faces: polygons.map { $0.pts.map { ($0 - lo) / size } })
        return p
    }
    static func sweep(profile: [SIMD2<Double>], path: [SIMD3<Double>]) throws -> [Geo.Poly] {
        guard Planar.isSimple(profile), (2...128).contains(path.count), path.allSatisfy(ModelValidation.finite) else { throw ModelValidation.Failure(message: "Use a simple closed profile and a path of 2–128 points.") }
        let shape = Planar.signedArea(profile) < 0 ? Array(profile.reversed()) : profile
        var rings: [[SIMD3<Double>]] = [], tangents: [SIMD3<Double>] = []
        var previousU: SIMD3<Double>?
        for i in path.indices {
            let before = path[i] - path[max(0, i - 1)], after = path[min(path.count - 1, i + 1)] - path[i]
            guard (i == 0 || norm(before) > 1e-7), (i == path.count - 1 || norm(after) > 1e-7) else { throw ModelValidation.Failure(message: "Sweep path points must be distinct.") }
            let tangent = simdNormalize(simdNormalize(before) + simdNormalize(after))
            guard norm(tangent) > 0.9 else { throw ModelValidation.Failure(message: "A sweep cannot reverse direction at a corner.") }
            let ref = previousU ?? (abs(tangent.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0))
            let u = simdNormalize(ref - tangent * simd_dot(ref, tangent)), v = cross(tangent, u)
            previousU = u; tangents.append(tangent)
            rings.append(shape.map { path[i] + u * $0.x + v * $0.y })
        }
        var faces: [Geo.Poly] = []
        for triangle in Planar.triangulate(shape) {
            let indices = triangle.map { shape.firstIndex(of: $0)! }
            if let f = SolidCSG.face(indices.map { rings[0][$0] }, normal: -tangents[0]) { faces.append(f) }
            if let f = SolidCSG.face(indices.map { rings.last![$0] }, normal: tangents.last!) { faces.append(f) }
        }
        for k in 0..<(rings.count - 1) {
            for i in shape.indices {
                let j = (i + 1) % shape.count
                let quad = [rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]]
                for triangle in [[quad[0], quad[1], quad[2]], [quad[0], quad[2], quad[3]]] {
                    if let f = SolidCSG.face(triangle, normal: simdNormalize(cross(triangle[1] - triangle[0], triangle[2] - triangle[0]))) { faces.append(f) }
                }
            }
        }
        return faces
    }
}

extension MachiningOperation {
    var openingBounds: (center: SIMD2<Double>, span: SIMD2<Double>) {
        guard let first = contour.first else { return (.zero,.zero) }
        let lo = contour.reduce(first) { SIMD2(min($0.x,$1.x),min($0.y,$1.y)) }
        let hi = contour.reduce(first) { SIMD2(max($0.x,$1.x),max($0.y,$1.y)) }
        return ((lo+hi)/2,hi-lo)
    }
    func repositioned(center: SIMD2<Double>, span: SIMD2<Double>) throws -> MachiningOperation {
        guard sketch == nil else { throw ModelValidation.Failure(message:"Edit this feature’s face sketch to change its shape or dimensions.") }
        let old = openingBounds
        guard center.x.isFinite,center.y.isFinite,span.x.isFinite,span.y.isFinite,span.x > 0,span.y > 0,old.span.x > 0,old.span.y > 0 else {
            throw ModelValidation.Failure(message:"Use finite coordinates and a positive opening size.")
        }
        var operation = self
        operation.contour = contour.map { center+($0-old.center)*span/old.span }
        operation.islands = islands?.map { $0.map { center+($0-old.center)*span/old.span } }
        return operation
    }
}
extension Document {
    @discardableResult func saveOperation(_ operation: MachiningOperation, partID: UUID) -> Bool {
        transaction {
            guard var p = part(partID),let index = p.operations?.firstIndex(where: { $0.id == operation.id }) else { throw ModelValidation.Failure(message:"The machining operation no longer exists.") }
            p.operations![index] = operation
            guard applyPartChanges([p]) else { throw ModelValidation.Failure(message:status) }
        }
    }
}
