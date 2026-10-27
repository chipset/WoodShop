import Foundation
import simd

enum MatingJointKind: String, Codable, CaseIterable { case dado = "Dado", mortise = "Stopped dado / mortise", rabbet = "Rabbet" }
struct MatingJoint: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Shelf joint"
    var shelf: UUID
    var receiver: UUID
    var axis: Int
    var positive: Bool
    var depth = 0.25
    var clearance = 0.005
    var kind = MatingJointKind.dado
    var autoSeat = true
    var suppressed = false
    var relief: CornerRelief? = nil
    var number: Int? = nil
    var cutID: UUID { DrillingPattern.stableID(id,"mating-cut") }
    var label: String { number.map { String(format:"J%03d",$0) } ?? "J-" + id.uuidString.prefix(6) }
}

enum MatingJoinery {
    static func regenerate(parts: inout [Part], joints: [MatingJoint]) throws {
        guard Set(joints.map(\.id)).count == joints.count else { throw ModelValidation.Failure(message:"Duplicate mating-joint identifiers.") }
        let ids = Set(parts.map(\.id))
        for joint in joints {
            guard ids.contains(joint.shelf),ids.contains(joint.receiver),joint.shelf != joint.receiver,
                  (0..<3).contains(joint.axis),joint.depth.isFinite,joint.depth > 0,joint.clearance.isFinite,joint.clearance >= 0 else {
                throw ModelValidation.Failure(message:joint.name + ": choose distinct existing parts and positive depth/nonnegative clearance.")
            }
        }
        var remaining = Set(joints.filter { !$0.suppressed && $0.autoSeat }.map(\.shelf)), ordered: [UUID] = []
        while !remaining.isEmpty {
            let roots = remaining.filter { donor in !joints.contains { !$0.suppressed && $0.autoSeat && $0.shelf == donor && remaining.contains($0.receiver) } }
            guard !roots.isEmpty else { throw ModelValidation.Failure(message:"Automatic shelf seating contains a dependency cycle.") }
            ordered += roots.sorted { $0.uuidString < $1.uuidString }; remaining.subtract(roots)
        }
        for donorID in ordered {
            for joint in joints where !joint.suppressed && joint.autoSeat && joint.shelf == donorID {
                let target = parts.first { $0.id == joint.receiver }!
                guard let index = parts.firstIndex(where: { $0.id == donorID }) else { continue }
                var donor = parts[index]
                let (normal,sign,_) = try axes(donor:donor,receiver:target,joint:joint)
                let floor = joint.positive ? target.size[joint.axis] - joint.depth : joint.depth
                let localOrigin = target.toLocal(donor.toWorld(.zero))
                let coordinate = (floor - localOrigin[joint.axis]) / sign
                let atMinimum = sign * (joint.positive ? 1.0 : -1) > 0
                let minimum = atMinimum ? coordinate : 0, maximum = atMinimum ? donor.size[normal] : coordinate
                guard maximum - minimum >= 1 / 32 else { throw ModelValidation.Failure(message:joint.name + ": seating would remove the shelf length. Check the receiving face and shelf placement.") }
                if abs(minimum) < 1e-8 && abs(maximum - donor.size[normal]) < 1e-8 { continue }
                let original = donor
                var shift = SIMD3<Double>.zero; shift[normal] = minimum
                let newWorldOrigin = donor.toWorld(shift)
                donor.size[normal] = maximum - minimum
                donor.origin += newWorldOrigin - donor.toWorld(.zero)
                if abs(donor.size[normal] - original.size[normal]) > 1e-7,donor.component != nil {
                    throw ModelValidation.Failure(message:joint.name + ": make the shelf component unique before automatically fitting its length.")
                }
                if abs(minimum) > 1e-7 {
                    for i in donor.cuts.indices where donor.cuts[i].mateID == nil { donor.cuts[i].lo -= shift; donor.cuts[i].hi -= shift }
                    for i in (donor.operations ?? []).indices {
                        let op = donor.operations![i]
                        donor.operations![i].contour = op.contour.map { $0 - SIMD2(shift[op.u],shift[op.v]) }
                    }
                }
                parts[index] = donor
            }
        }
        // Generated cuts keep their previous position in the feature sequence and have stable identifiers.
        for i in parts.indices { parts[i].cuts.removeAll { $0.mateID != nil } }
        for joint in joints where !joint.suppressed {
            let donor = parts.first { $0.id == joint.shelf }!
            let index = parts.firstIndex { $0.id == joint.receiver }!
            let target = parts[index]
            guard joint.depth <= target.size[joint.axis] + 1e-7 else { throw ModelValidation.Failure(message:joint.name + ": dado depth exceeds the receiving board thickness.") }
            let (_,_,across) = try axes(donor:donor,receiver:target,joint:joint)
            let run = (0..<3).first { $0 != across && $0 != joint.axis }!
            let corners = (0..<8).map { i -> SIMD3<Double> in
                let p = SIMD3(i & 1 == 0 ? 0 : donor.size.x,i & 2 == 0 ? 0 : donor.size.y,i & 4 == 0 ? 0 : donor.size.z)
                return target.toLocal(donor.toWorld(p))
            }
            let lo = corners.reduce(corners[0],pointwiseMin),hi = corners.reduce(corners[0],pointwiseMax)
            guard hi[run] > 0,lo[run] < target.size[run],lo[across] >= -1e-6,hi[across] <= target.size[across] + 1e-6 else {
                throw ModelValidation.Failure(message:joint.name + ": the shelf does not line up with the receiving face. Move it into the board's width/height first.")
            }
            var cutLo = SIMD3<Double>.zero,cutHi = target.size
            cutLo[joint.axis] = joint.positive ? target.size[joint.axis] - joint.depth : 0
            cutHi[joint.axis] = joint.positive ? target.size[joint.axis] : joint.depth
            cutLo[across] = max(0,lo[across]); cutHi[across] = min(target.size[across],hi[across])
            if joint.kind == .mortise { cutLo[run] = max(0,lo[run]); cutHi[run] = min(target.size[run],hi[run]) }
            if joint.kind == .rabbet && min(abs(cutLo[across]),abs(target.size[across] - cutHi[across])) > 1e-5 {
                throw ModelValidation.Failure(message:joint.name + ": a rabbet must touch an edge. Move the shelf to the edge or choose a dado.")
            }
            let kind = joint.kind == .mortise ? "Mortise" : joint.kind.rawValue
            var cut = Cut(kind:kind,lo:cutLo,hi:cutHi,faceAxis:joint.axis,facePositive:joint.positive,runAxis:run,
                          relief:joint.relief,allowance:joint.clearance,mateID:joint.id,name:joint.label + " · " + joint.name)
            cut.id = joint.cutID
            parts[index].cuts.append(cut)
        }
    }
    private static func axes(donor: Part,receiver: Part,joint: MatingJoint) throws -> (Int,Double,Int) {
        let relative = receiver.rotMatrix.transpose * donor.rotMatrix
        for column in 0..<3 {
            guard (0..<3).map({ abs(relative[column][$0]) }).max()! > 1 - 1e-6 else {
                throw ModelValidation.Failure(message:joint.name + ": align the shelf square to the receiving board before creating this joint.")
            }
        }
        let normal = (0..<3).max { abs(relative[$0][joint.axis]) < abs(relative[$1][joint.axis]) }!
        let thicknessDirection = relative[donor.materialAxes.t]
        let across = (0..<3).max { abs(thicknessDirection[$0]) < abs(thicknessDirection[$1]) }!
        guard across != joint.axis else { throw ModelValidation.Failure(message:joint.name + ": choose the inward face receiving the shelf end, rather than a face parallel to the shelf.") }
        return (normal,relative[normal][joint.axis],across)
    }
}
extension Part {
    func toLocal(_ world: SIMD3<Double>) -> SIMD3<Double> { size / 2 + rotMatrix.transpose * (world - center) }
}
