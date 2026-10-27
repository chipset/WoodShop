import Foundation

enum ModelValidation {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    static func finite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
    /// Check every axis before any geometry or regeneration code indexes a SIMD vector.
    static func axes(_ p: Part) -> String? {
        func valid(_ axis: Int?) -> Bool { axis.map { (0..<3).contains($0) } ?? true }
        guard valid(p.thicknessAxis),valid(p.grainDirection),p.cuts.allSatisfy({ valid($0.faceAxis) && valid($0.runAxis) && ($0.faceAxis == nil || $0.faceAxis != $0.runAxis) }),
              (p.operations ?? []).allSatisfy({ valid($0.axis) }),p.trims.allSatisfy({ valid($0.axis) && valid($0.run) && $0.axis != $0.run }),
              (p.patterns ?? []).allSatisfy({ valid($0.axis) }),
              (p.edges ?? []).allSatisfy({ (0..<3).contains($0.axis1) && (0..<3).contains($0.axis2) && ($0.kind == .arch || $0.axis1 != $0.axis2) && $0.size.isFinite && $0.size > 0 && ($0.from ?? 0).isFinite && ($0.to ?? 1).isFinite && ($0.from ?? 0) >= 0 && (($0.from == nil || $0.to == nil) || $0.to! > $0.from!) }) else { return "Invalid part or machining axis." }
        if p.cuts.contains(where: { c in (c.planes ?? []).contains { !finite($0.p) || !finite($0.n) } }) { return "Invalid angled cut plane." }
        if let profile = p.profile, !valid(profile.u) || !valid(profile.v) || profile.u == profile.v { return "Invalid curve plane." }
        return nil
    }
    static func part(_ p: Part) -> String? {
        if let message = axes(p) { return message }
        if let shop = p.shop { do { try shop.validate() } catch { return error.localizedDescription } }
        guard finite(p.origin), finite(p.size), finite(p.rot), (0..<3).allSatisfy({ p.size[$0] >= 1 / 32 }) else {
            return "Board dimensions must be finite and at least 1/32 inch."
        }
        guard p.thicknessAxis.map({ (0..<3).contains($0) }) ?? true,
              p.grainDirection.map({ (0..<3).contains($0) }) ?? true else { return "Invalid material axes." }
        if let t = p.thicknessAxis, let l = p.grainDirection, t == l { return "Grain must run along the board face." }
        if let mesh = p.mesh {
            guard !mesh.faces.isEmpty, mesh.faces.count <= 25000,
                  mesh.faces.allSatisfy({ $0.count >= 3 && $0.allSatisfy { point in finite(point) && (0..<3).allSatisfy { a in point[a] >= -1e-6 && point[a] <= 1 + 1e-6 } } }) else { return "Invalid solid mesh." }
        }
        if let mesh = p.mesh {
            for face in mesh.faces {
                let points = face.map { $0 * p.size }
                let anchor = points[0]
                guard points.dropFirst().dropLast().enumerated().contains(where: { index,point in
                    norm(cross(point-anchor,points[index+2]-anchor)) > 1e-10
                }) else { return "A solid contains a degenerate face." }
            }
        }
        for pattern in p.patterns ?? [] { do { _ = try pattern.generated(size:p.size) } catch { return error.localizedDescription } }
        if let order = p.featureOrder, Set(order).count != order.count { return "Feature history contains duplicate steps." }
        let featureIDs = p.cuts.map(\.id) + p.trims.map(\.id) + (p.operations ?? []).map(\.id) + (p.patterns ?? []).map(\.id)
        guard Set(featureIDs).count == featureIDs.count else { return "Feature identifiers must be unique within a part." }
        let available = Set(p.cuts.map { FeatureStep(kind:.cut,feature:$0.id) } + p.trims.map { FeatureStep(kind:.trim,feature:$0.id) }
            + (p.operations ?? []).map { FeatureStep(kind:.operation,feature:$0.id) } + (p.patterns ?? []).map { FeatureStep(kind:.pattern,feature:$0.id) })
        guard (p.featureOrder ?? []).allSatisfy(available.contains) else { return "Feature history refers to a missing feature." }
        // Suppressed definitions must also be safe to inspect and re-enable.
        for op in p.operations ?? [] { if let error = op.validation(size:p.size,checkStock:op.suppressed != true) { return error } }
        if let profile = p.profile, let error = profile.validation(size: p.size) { return error }
        guard Set(p.cuts.map(\.id)).count == p.cuts.count,
              Set(p.trims.map(\.id)).count == p.trims.count else { return "Duplicate joinery identifiers." }
        for c in p.cuts {
            guard c.faceAxis.map({ (0..<3).contains($0) }) ?? true,
                  c.runAxis.map({ (0..<3).contains($0) }) ?? true,
                  !(c.faceAxis != nil && c.faceAxis == c.runAxis) else { return "Invalid joinery axes." }
            guard finite(c.lo), finite(c.hi), (0..<3).allSatisfy({ c.hi[$0] > c.lo[$0] }) else { return "Joinery must have positive, finite dimensions." }
            if let allowance = c.allowance, !allowance.isFinite || allowance < 0 { return "Joint allowance must be finite and nonnegative." }
            if let relief = c.relief {
                let a = c.faceAxis ?? p.materialAxes.t, u = (a + 1) % 3, v = (a + 2) % 3
                guard relief.diameter.isFinite, relief.diameter > 0, relief.corners.count == 4,
                      relief.diameter <= min(c.hi[u] - c.lo[u], c.hi[v] - c.lo[v]) + (c.allowance ?? 0), !c.additive else { return "Reliefs need a cutter that fits the pocket width and length." }
            }
            if c.suppressed == true { continue }
            if c.additive {
                let touching = (0..<3).allSatisfy { c.lo[$0] <= p.size[$0] + 1e-7 && c.hi[$0] >= -1e-7 }
                let overlaps = (0..<3).filter { min(c.hi[$0], p.size[$0]) - max(c.lo[$0], 0) > 1e-7 }.count
                guard touching, overlaps >= 2 else { return "Tenons must attach to a board face." }
                if let profile = p.profile, !profile.contacts(Box(lo: c.lo, hi: c.hi), size: p.size) {
                    return "A tenon no longer touches the curved board. Move the joint or adjust the outline."
                }
            } else {
                guard (0..<3).allSatisfy({ min(c.hi[$0], p.size[$0]) > max(c.lo[$0], 0) }) else { return "A cut falls entirely outside the board." }
            }
        }
        for t in p.trims {
            guard (0..<3).contains(t.axis), (0..<3).contains(t.run), t.axis != t.run,
                  t.angle.isFinite, abs(t.angle) < 89.9 else { return "Miter and bevel angles must be between -89.9° and 89.9°." }
        }
        return nil
    }
    static func nesting(sheetL: Double, sheetW: Double, gap: Double, registration: Registration? = nil) -> String? {
        guard sheetL.isFinite, sheetW.isFinite, gap.isFinite, sheetL > 0, sheetW > 0, gap >= 0,
              2 * gap < min(sheetL, sheetW) else { return "Sheet dimensions must be positive, with spacing smaller than half the sheet." }
        if let registration, registration.enabled {
            guard registration.diameter.isFinite, registration.inset.isFinite, registration.diameter > 0,
                  registration.inset > registration.diameter / 2, 2 * registration.inset + registration.diameter < sheetW,
                  registration.inset + registration.diameter + 2 * gap < sheetL else { return "Registration pins must fit the stock with a clear strip along the sheet edge." }
        }
        return nil
    }
    static func validate(_ p: Project) throws {
        guard (1...6).contains(p.version) else { throw Failure(message: "This project version is not supported.") }
        guard p.snap.isFinite, p.snap > 0, p.stockLength.isFinite, p.stockLength >= 1 / 32,
              p.rectThickness.isFinite, p.rectThickness >= 1 / 32 else { throw Failure(message: "Invalid stock or snap settings.") }
        if let message = nesting(sheetL: p.sheetLength, sheetW: p.sheetWidth, gap: p.nestGap, registration: p.studio?.registration) { throw Failure(message: message) }
        guard Set(p.parts.map(\.id)).count == p.parts.count else { throw Failure(message: "Duplicate board identifiers.") }
        for board in p.parts { if let message = part(board) { throw Failure(message: "\(board.name): \(message)") } }
        let grainGroups = Dictionary(grouping:p.parts.filter { $0.hardware != true && !($0.shop?.grainMatchGroup ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty },by:{ $0.shop!.grainMatchGroup.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() })
        for (name,boards) in grainGroups {
            let species = Set(boards.map { $0.species.rawValue }),thicknesses = boards.map { $0.size[$0.materialAxes.t] }
            guard species.count == 1,thicknesses.allSatisfy({ abs($0-thicknesses[0]) < 1e-6 }) else { throw Failure(message:"Grain match ‘\(name)’ mixes materials or stock thicknesses. Keep one material and thickness per continuous sheet.") }
            guard Set(boards.map { $0.cncTopPositive ?? true }).count == 1 else { throw Failure(message:"Grain match ‘\(name)’ mixes CNC top faces. Use one visible face orientation for a continuous grain run.") }
            let orders = boards.compactMap { $0.shop?.grainMatchOrder }
            guard Set(orders).count == orders.count else { throw Failure(message:"Grain match ‘\(name)’ has duplicate sequence numbers. Give each selected panel a distinct order.") }
        }
        if let studio = p.studio {
            for stock in studio.offcuts ?? [] { try stock.validate() }
            guard Set((studio.offcuts ?? []).map(\.id)).count == (studio.offcuts ?? []).count else { throw Failure(message:"Duplicate offcut identifiers.") }
            for template in studio.hardwareTemplates ?? [] { try template.validate() }
            for rate in studio.materialRates ?? [] { guard rate.perSquareFoot.isFinite,rate.perBoardFoot.isFinite,rate.perSquareFoot>=0,rate.perBoardFoot>=0,rate.bandPerFoot.map({ $0.isFinite && $0>=0 }) ?? true else { throw Failure(message:"Material rates must be finite and nonnegative.") } }
            if let waste = studio.lumberWaste,(!waste.isFinite || waste<0 || waste>2) { throw Failure(message:"Use a lumber waste allowance between 0 and 200 percent.") }
            try AssemblyRelations.validateDrivers(parts:p.parts,relations:studio.relations ?? [],joints:studio.matingJoints ?? [])
            var related = p.parts
            try AssemblyRelations.rebuild(&related,relations:studio.relations ?? [],values:Parametric.values(studio.parameters ?? []))
            guard related.map(\.origin) == p.parts.map(\.origin) else { throw Failure(message:"An assembly relationship conflicts with a driving position or linked joinery. Choose one placement rule or regenerate the assembly.") }
            if let profile = studio.setupProfile { try profile.validate() }
            for guide in studio.guides {
                guard finite(guide.point), finite(guide.direction), abs(norm(guide.direction) - 1) < 1e-6 else { throw Failure(message: "Invalid construction guide.") }
            }
            for d in studio.dimensions { guard finite(d.a), finite(d.b) else { throw Failure(message: "Invalid dimension.") } }
            if let s = studio.section, !(0..<3).contains(s.axis) || !s.value.isFinite { throw Failure(message: "Invalid section plane.") }
            for scene in studio.scenes {
                guard finite(scene.target), scene.distance.isFinite, scene.distance > 0, scene.yaw.isFinite, scene.pitch.isFinite else { throw Failure(message: "Invalid saved scene.") }
                if let s = scene.section, !(0..<3).contains(s.axis) || !s.value.isFinite { throw Failure(message: "Invalid saved section.") }
            }
            for item in studio.library { for part in item.parts { if let error = self.part(part) { throw Failure(message: error) } } }
        }
        if let joints = p.studio?.matingJoints, !joints.isEmpty {
            var regenerated = p.parts
            try MatingJoinery.regenerate(parts:&regenerated,joints:joints)
            for part in regenerated {
                var q = part
                for i in q.cuts.indices { q.cuts[i].mateID = nil }
                if let error = self.part(q) { throw Failure(message:part.name + ": " + error) }
            }
            guard regenerated == p.parts else { throw Failure(message:"Linked joinery is out of date. Regenerate the design before exporting.") }
        }
        let joints = p.studio?.matingJoints ?? []
        for part in p.parts {
            for cut in part.cuts {
                if let mate = cut.mateID,!joints.contains(where: { $0.id == mate && $0.receiver == part.id && $0.cutID == cut.id && !$0.suppressed }) {
                    throw Failure(message:part.name + ": a generated joint has lost its mating relationship. Detach or rebuild the joint.")
                }
            }
        }
        let parameterValues = try Parametric.values(p.studio?.parameters ?? [])
        for part in p.parts {
            try Parametric.validateBindings(part,values:parameterValues)
            for op in part.operations ?? [] {
                if let sketch = op.sketch {
                    guard part.mesh == nil else { throw Failure(message:part.name+": face sketches require an extruded board, not a general mesh.") }
                    if let profile = part.profile,profile.thickness != op.axis { throw Failure(message:part.name+": sketch on the front or back flat face of the curved panel.") }
                    if op.suppressed != true,!FaceSketchEditing.insideProfile(op,part:part) { throw Failure(message:part.name+": the face sketch extends outside the curved board outline.") }
                    guard try sketch.generated(from:op,size:part.size,values:parameterValues,references:part.operations ?? []) == op else { throw Failure(message:part.name+": face sketch machining is out of date. Regenerate before exporting.") }
                }
            }
            for pattern in part.patterns ?? [] {
                var evaluated = pattern; try evaluated.evaluate(parameterValues)
                guard evaluated == pattern else { throw Failure(message:part.name + ": drilling pattern expressions are out of date. Regenerate before saving or exporting.") }
            }
        }
        let ids = Set(p.parts.map(\.id))
        var destinations: Set<String> = []
        for link in p.links {
            guard ids.contains(link.source), ids.contains(link.target), link.source != link.target,
                  (0..<3).contains(link.sourceAxis), (0..<3).contains(link.targetAxis), link.offset.isFinite,
                  destinations.insert("\(link.target)-\(link.targetAxis)").inserted else { throw Failure(message: "Invalid dimension relationship.") }
            var reachable: Set<UUID> = [link.target]
            for _ in 0...p.links.count {
                for l in p.links where reachable.contains(l.source) { reachable.insert(l.target) }
            }
            guard !reachable.contains(link.source) else { throw Failure(message: "Dimension relationships contain a cycle.") }
            if let source = p.parts.first(where: { $0.id == link.source }), let target = p.parts.first(where: { $0.id == link.target }) {
                let expected = source.size[link.sourceAxis] + link.offset
                guard expected.isFinite, expected >= 1 / 32,
                      abs(target.size[link.targetAxis] - expected) < 1e-6 else {
                    throw Failure(message: "A linked dimension does not match its source.")
                }
            }
        }
    }
}
