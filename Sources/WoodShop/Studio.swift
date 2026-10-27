import AppKit
import simd

struct ConstructionGuide: Codable, Equatable, Identifiable {
    var id = UUID()
    var point: SIMD3<Double>
    var direction: SIMD3<Double>
}
struct ModelDimension: Codable, Equatable, Identifiable {
    var id = UUID()
    var a: SIMD3<Double>
    var b: SIMD3<Double>
    var name = ""
}
struct SectionPlane: Codable, Equatable {
    var axis = 0
    var value = 0.0
    var keepPositive = false
}
struct SavedScene: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var target: SIMD3<Double>
    var distance: Double
    var yaw: Double
    var pitch: Double
    var ortho: Bool
    var visible: [UUID]
    var section: SectionPlane?
}
struct Registration: Codable, Equatable {
    var enabled = false
    var diameter = 0.25
    var inset = 1.0
}
struct LibraryItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var parts: [Part]
}
struct StudioState: Codable, Equatable {
    var guides: [ConstructionGuide] = []
    var dimensions: [ModelDimension] = []
    var scenes: [SavedScene] = []
    var section: SectionPlane? = nil
    var registration = Registration()
    var library: [LibraryItem] = []
    var parameters: [DesignParameter]? = nil
    var history: [HistoryEntry]? = nil
    var matingJoints: [MatingJoint]? = nil
    var setupProfile: CNCSetupProfile? = nil
    var assemblySteps: [AssemblyStep]? = nil
    var nextShopNumber: Int? = nil
    var relations: [AssemblyRelation]? = nil
    var offcuts: [SheetStock]? = nil
    var useOffcuts: Bool? = nil
    var hardwareTemplates: [HardwareTemplate]? = nil
    var materialRates: [MaterialRate]? = nil
    var lumberWaste: Double? = nil
}

extension Document {
    /// Validate a compound change once and keep it as a single undo action.
    @discardableResult func transaction(_ change: () throws -> Void) -> Bool {
        checkpoint()
        do {
            try change()
            try Regeneration.rebuild(parts:&parts,links:links,studio:studio)
            try ModelValidation.validate(project)
            if historyOrigin?.parts != parts { selectedSurface = nil }
            fixSelection()
            discardCheckpointIfUnchanged()
            return true
        } catch {
            cancelCheckpoint(); status = error.localizedDescription
            return false
        }
    }
    func makeComponents(unique: Bool = false) {
        transaction {
            for i in parts.indices where selectedIDs.contains(parts[i].id) {
                if unique || parts[i].component == nil { parts[i].component = UUID() }
            }
        }
    }
    func selectAssembly(_ path: String) {
        let ids = Set(parts.filter { $0.group == path || $0.group?.hasPrefix(path + "/") == true }.map(\.id))
        selection = ids.first; selectedIDs = ids
    }
    func rotateAround(axis: Int, degrees: Double, pivot: SIMD3<Double>, copies: Int = 0) {
        guard (0..<3).contains(axis), degrees.isFinite, ModelValidation.finite(pivot), (0...100).contains(copies) else { status = "Invalid rotation or copy count."; return }
        var direction = SIMD3<Double>.zero; direction[axis] = 1
        let originals = parts.filter { selectedIDs.contains($0.id) }
        transaction {
            var ids: Set<UUID> = []
            for step in 1...max(1, copies) {
                var copyIDs: [UUID:UUID] = [:]
                let r = simd_double3x3(simd_quatd(angle: degrees * Double(step) * .pi / 180, axis: direction))
                for original in originals {
                    var p = original
                    let center = pivot + r * (p.center - pivot)
                    p.rot = MeshTransforms.euler(r * p.rotMatrix)
                    p.origin = center - p.size / 2
                    if copies > 0 { p.id = UUID(); copyIDs[original.id] = p.id; p.name += " copy"; p.bindings?.removeAll { [.position,.rotation].contains($0.target) }; parts.append(p) }
                    else if let i = parts.firstIndex(where: { $0.id == p.id }) { parts[i] = p }
                    ids.insert(p.id)
                }
                if copies > 0 { replicateMates(copyIDs) }
            }
            selection = ids.first; selectedIDs = ids
        }
    }
    func linearArray(count: Int, step: SIMD3<Double>) {
        guard (1...100).contains(count), ModelValidation.finite(step) else { status = "Use 1–100 copies and finite spacing."; return }
        let originalIDs = selectedIDs
        let originals = parts.filter { originalIDs.contains($0.id) }
        transaction {
            var ids: Set<UUID> = []
            for n in 1...count {
                var mapping: [UUID: UUID] = [:]
                for var p in originals {
                    let old = p.id; p.id = UUID(); mapping[old] = p.id
                    p.name += " \(n)"; p.origin += Double(n) * step
                    p.bindings?.removeAll { [.position,.rotation].contains($0.target) }
                    parts.append(p); ids.insert(p.id)
                }
                let dependencies = links.filter { originalIDs.contains($0.target) }
                replicateMates(mapping)
                links += dependencies.map { DimensionLink(source: mapping[$0.source] ?? $0.source, sourceAxis: $0.sourceAxis,
                    target: mapping[$0.target]!, targetAxis: $0.targetAxis, offset: $0.offset) }
            }
            selection = ids.first; selectedIDs = ids
        }
    }
    func scaleSelection(_ scale: SIMD3<Double>, pivot: SIMD3<Double>) {
        guard ModelValidation.finite(scale), (0..<3).allSatisfy({ scale[$0] > 0 }), ModelValidation.finite(pivot) else { status = "Scale factors must be positive."; return }
        transaction {
            for i in parts.indices where selectedIDs.contains(parts[i].id) {
                let old = parts[i]
                // World scaling handles rotated and curved solids without distorting local Euler axes.
                let polygons = Geo.polys(for: old).compactMap { poly -> Geo.Poly? in
                    let pts = poly.pts.map { pivot + (old.toWorld($0) - pivot) * scale }
                    return SolidCSG.face(pts, normal: simdNormalize(cross(pts[1] - pts[0], pts[2] - pts[0])))
                }
                var p = try MeshTools.part(polygons: polygons, name: old.name, species: old.species)
                p.id = old.id; p.shopNumber = old.shopNumber; p.group = old.group; p.hidden = old.hidden; p.hardware = old.hardware
                parts[i] = p
            }
            links.removeAll { selectedIDs.contains($0.target) || selectedIDs.contains($0.source) }
        }
    }
    func mirrorSelection(axis: Int, plane: Double, copy: Bool) {
        guard (0..<3).contains(axis), plane.isFinite else { return }
        let originals = parts.filter { selectedIDs.contains($0.id) }
        transaction {
            var ids: Set<UUID> = []
            var copyIDs: [UUID:UUID] = [:]
            for original in originals {
                var p = original.reflectedLocal(axis: 0)
                var world = matrix_identity_double3x3, local = matrix_identity_double3x3
                world[axis][axis] = -1; local[0][0] = -1
                p.rot = MeshTransforms.euler(world * original.rotMatrix * local)
                var center = original.center; center[axis] = 2 * plane - center[axis]
                p.origin = center - p.size / 2
                p.id = copy ? UUID() : original.id; copyIDs[original.id] = p.id; p.name = original.name + (copy ? " mirror" : "")
                if copy { parts.append(p) } else if let i = parts.firstIndex(where: { $0.id == p.id }) { parts[i] = p }
                ids.insert(p.id)
            }
            if copy { replicateMates(copyIDs,reflectLocalX:true) }
            else { for i in (studio.matingJoints ?? []).indices where selectedIDs.contains(studio.matingJoints![i].receiver) && studio.matingJoints![i].axis == 0 { studio.matingJoints![i].positive.toggle() } }
            if !copy { links.removeAll { selectedIDs.contains($0.source) || selectedIDs.contains($0.target) } }
            selection = ids.first; selectedIDs = ids
        }
    }
    func addOperations(_ operations: [MachiningOperation], to id: UUID) {
        edit(id) { $0.operations = ($0.operations ?? []) + operations }
    }
    func rememberMeasurement(name: String = "") {
        guard lastMeasurement.count == 2 else { status = "Use Tape Measure to pick two points first."; return }
        transaction { studio.dimensions.append(ModelDimension(a: lastMeasurement[0], b: lastMeasurement[1], name: name)) }
    }
    func saveLibraryItem(name: String) {
        let selected = parts.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        transaction { studio.library.append(LibraryItem(name: name, parts: selected)) }
    }
    func insertLibrary(_ item: LibraryItem) {
        transaction {
            var ids: Set<UUID> = []
            for var p in item.parts {
                p.id = UUID(); p.shopNumber = nil; p.component = nil; p.origin += SIMD3(2,0,2)
                p.bindings?.removeAll { [.position,.rotation].contains($0.target) }
                for i in p.cuts.indices { p.cuts[i].mateID = nil }
                parts.append(p); ids.insert(p.id)
            }
            selection = ids.first; selectedIDs = ids
        }
    }
    func addHardware(_ kind: String) {
        var p: Part
        switch kind {
        case "Drawer slide": p = Part(name: "Drawer slide (reference)", origin: .zero, size: SIMD3(18, 1.75, 0.5), species: .mdf)
        case "Hinge": p = Part(name: "Hinge (reference)", origin: .zero, size: SIMD3(2.5, 0.125, 1.5), species: .mdf)
        default:
            p = Part(name: "Dowel", origin: .zero, size: SIMD3(0.375, 1.5, 0.375), species: .maple)
            p.thicknessAxis = 1; p.grainDirection = 0
            p.profile = .preset(.oval, part: p)
        }
        p.hardware = true; add(p)
    }
    func offsetProfile(_ distance: Double) {
        guard var p = selectedPart else { return }
        guard p.mesh == nil else { status = "Offset an editable board profile; this part is a general solid."; return }
        guard !(p.operations ?? []).contains(where: { $0.sketch != nil }) else { status = "Offset the board outline before adding face sketches. Existing sketch coordinates must keep their stock origin."; return }
        let axes = p.materialAxes
        let profile = p.profile ?? BoardProfile(u: axes.l, v: axes.w, nodes: [.init(point: .zero), .init(point: SIMD2(1, 0)), .init(point: SIMD2(1, 1)), .init(point: SIMD2(0, 1))])
        do {
            let points = try Planar.offset(profile.contour(size: p.size), by: distance)
            let low = points.reduce(points[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }
            let high = points.reduce(points[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
            var delta = SIMD3<Double>.zero; delta[profile.u] = low.x; delta[profile.v] = low.y
            let worldStart = p.toWorld(delta)
            p.size[profile.u] = high.x - low.x; p.size[profile.v] = high.y - low.y
            p.profile = BoardProfile(u: profile.u, v: profile.v, nodes: points.map { .init(point: ($0 - low) / (high - low)) })
            for i in p.cuts.indices { p.cuts[i].lo -= delta; p.cuts[i].hi -= delta }
            for i in (p.operations ?? []).indices {
                let op = p.operations![i]
                p.operations![i].contour = op.contour.map { $0 - SIMD2(delta[op.u],delta[op.v]) }
            }
            p.bindings?.removeAll { [.size,.position].contains($0.target) }
            p.origin += worldStart - p.toWorld(.zero)
            p.component = nil
            edit(p.id) { $0 = p }
        } catch { status = error.localizedDescription }
    }
    func extrudeSurface(amount: Double) {
        guard let p = selectedPart, let index = selectedSurface else { status = "Select a face first."; return }
        let polys = Geo.polys(for: p)
        guard polys.indices.contains(index), amount.isFinite, abs(amount) > 1e-7 else { return }
        let face = polys[index], d = face.n * amount
        var prism: [Geo.Poly] = []
        if let f = SolidCSG.face(face.pts, normal: -face.n) { prism.append(f) }
        if let f = SolidCSG.face(face.pts.map { $0 + d }, normal: face.n) { prism.append(f) }
        for i in face.pts.indices {
            let a = face.pts[i], b = face.pts[(i + 1) % face.pts.count]
            if let f = SolidCSG.face([a, b, b + d, a + d], normal: simdNormalize(cross(b - a, d))) { prism.append(f) }
        }
        if amount < 0 { prism = prism.map { Geo.Poly(pts: $0.pts.reversed(), n: -$0.n) } }
        let result = amount > 0 ? SolidCSG.union(polys, prism) : SolidCSG.subtract(polys, prism)
        do {
            var next = try MeshTools.part(polygons: result.map { poly in Geo.Poly(pts: poly.pts.map(p.toWorld), n: p.dirToWorld(poly.n)) }, name: p.name, species: p.species)
            next.id = p.id; next.shopNumber = p.shopNumber; next.group = p.group; next.hardware = p.hardware
            edit(p.id) { $0 = next }; selectedSurface = nil
        } catch { status = error.localizedDescription }
    }
}

enum MeshTransforms {
    static func euler(_ r: simd_double3x3) -> SIMD3<Double> {
        let y = asin(max(-1, min(1, -r[0].z)))
        let x: Double, z: Double
        if abs(cos(y)) > 1e-7 { x = atan2(r[1].z, r[2].z); z = atan2(r[0].y, r[0].x) }
        else { x = atan2(-r[2].y, r[1].y); z = 0 }
        return SIMD3(x, y, z) * (180 / .pi)
    }
}

extension Planar {
    /// Mitered offset; reject collapsed or crossing results rather than exporting broken contours.
    static func offset(_ input: [SIMD2<Double>], by distance: Double) throws -> [SIMD2<Double>] {
        guard distance.isFinite, Planar.isSimple(input) else { throw ModelValidation.Failure(message: "Offset needs a simple closed outline.") }
        let points = signedArea(input) < 0 ? Array(input.reversed()) : input
        var result: [SIMD2<Double>] = []
        for i in points.indices {
            let p = points[(i + points.count - 1) % points.count], q = points[i], r = points[(i + 1) % points.count]
            let a = simd_normalize(q - p), b = simd_normalize(r - q)
            let n = SIMD2(a.y, -a.x), m = SIMD2(b.y, -b.x)
            let denominator = cross(a, b)
            if abs(denominator) < 1e-9 { result.append(q + n * distance); continue }
            let start = q + n * distance, end = q + m * distance
            let t = cross(end - start, b) / denominator
            guard abs(t) < max(1, abs(distance) * 100) else { throw ModelValidation.Failure(message: "Offset would create an excessively sharp corner.") }
            result.append(start + a * t)
        }
        if distance < 0 {
            for point in result {
                var closest = Double.infinity
                for i in points.indices {
                    let a = points[i], b = points[(i + 1) % points.count], d = b - a
                    let t = max(0, min(1, simd_dot(point - a, d) / simd_length_squared(d)))
                    closest = min(closest, simd_length(point - a - t * d))
                }
                guard closest >= abs(distance) - 1e-6 else { throw ModelValidation.Failure(message: "The inset is larger than the available material.") }
            }
        }
        guard isSimple(result), signedArea(result) > 1e-7,
              distance >= 0 || signedArea(result) < signedArea(points) else { throw ModelValidation.Failure(message: "Offset collapses or crosses the outline.") }
        return result
    }
}

extension Part {
    /// Reflect in a local coordinate plane while retaining editable CNC features.
    func reflectedLocal(axis: Int) -> Part {
        var p = self
        func reflect(_ v: SIMD3<Double>) -> SIMD3<Double> { var q = v; q[axis] = size[axis] - v[axis]; return q }
        p.cuts = cuts.map { old in
            var c = old
            c.lo[axis] = size[axis] - old.hi[axis]; c.hi[axis] = size[axis] - old.lo[axis]
            if c.faceAxis == axis, let positive = c.facePositive { c.facePositive = !positive }
            let normal = old.faceAxis ?? materialAxes.t, run = old.runAxis ?? (0..<3).first { $0 != normal }!
            let across = (0..<3).first { $0 != normal && $0 != run }!
            if axis == across { c.offsetFromFar = !(old.offsetFromFar ?? false) }
            if var relief = c.relief {
                let a = c.faceAxis ?? materialAxes.t, u = (a + 1) % 3, v = (a + 2) % 3
                if axis == u { relief.corners = [relief.corners[1],relief.corners[0],relief.corners[3],relief.corners[2]] }
                if axis == v { relief.corners = [relief.corners[3],relief.corners[2],relief.corners[1],relief.corners[0]] }
                c.relief = relief
            }
            return c
        }
        p.patterns = patterns?.map { $0.reflected(axis:axis) }
        p.operations = operations?.map { old in
            var op = old
            if op.axis == axis { op.positive.toggle() }
            if var sketch = old.sketch {
                let transform = SketchOrientation(x:SIMD2(op.u == axis ? -1 : 1,0),y:SIMD2(0,op.v == axis ? -1 : 1),offset:SIMD2(op.u == axis ? 1 : 0,op.v == axis ? 1 : 0))
                sketch.orientation = sketch.orientation.followed(by:transform);op.sketch = sketch
            }
            op.contour = old.contour.map { pt in var q = pt; if op.u == axis { q.x = size[axis] - q.x }; if op.v == axis { q.y = size[axis] - q.y }; return q }
            op.islands = old.islands?.map { hole in hole.map { pt in var q = pt;if op.u == axis { q.x = size[axis]-q.x };if op.v == axis { q.y = size[axis]-q.y };return q } }
            return op
        }
        p.profile = profile.map { old in
            var profile = old
            func point(_ q: SIMD2<Double>) -> SIMD2<Double> { var r = q; if old.u == axis { r.x = 1 - r.x }; if old.v == axis { r.y = 1 - r.y }; return r }
            profile.nodes = old.nodes.map { .init(point: point($0.point), incoming: $0.incoming.map(point), outgoing: $0.outgoing.map(point)) }
            return profile
        }
        p.mesh = mesh.map { mesh in MeshSolid(faces: mesh.faces.map { face in face.reversed().map { pt in var q = pt; q[axis] = 1 - q[axis]; return q } }) }
        p.trims = trims.map { old in
            var t = old
            if t.axis == axis { t.positive.toggle() }
            let across = (0..<3).first { $0 != t.axis && $0 != t.run }!
            if across == axis { t.farEdge.toggle() }
            return t
        }
        if axis == materialAxes.t { p.cncTopPositive = !(cncTopPositive ?? true) }
        p.component = nil; p.bindings?.removeAll { [.position,.rotation].contains($0.target) }
        return p
    }
}
