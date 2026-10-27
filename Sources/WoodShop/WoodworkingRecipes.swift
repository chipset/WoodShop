import Foundation

enum MachiningRecipe: String,CaseIterable,Identifiable {
    case shelfPins = "Add shelf pins",hingeCups = "Add hinge cups",dado = "Fit a dado to a shelf",dogbones = "Add dogbones"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .shelfPins: return "Two rows of holes at 32 mm spacing, saved as an editable pattern."
        case .hingeCups: return "35 mm cups near one edge. Adjust the offsets to match your hinge hardware."
        case .dado: return "Choose a shelf and receiving boards; the joint follows the shelf thickness and position."
        case .dogbones: return "Add cutter relief to the selected part’s rectangular pockets and linked joints."
        }
    }
    func pattern(part: Part,face: FaceRef?) -> DrillingPattern {
        var p = DrillingPattern();p.axis = face?.axis ?? part.materialAxes.t;p.positive = face?.positive ?? part.cncTopPositive ?? true
        p.depth = min(self == .hingeCups ? 0.5 : 0.375,part.size[p.axis])
        let longU = part.size[p.u] >= part.size[p.v]
        if self == .shelfPins {
            p.name = "Shelf pins · 32 mm";p.diameter = 5/25.4;p.margin = SIMD2(repeating:1.5)
            let length = part.size[longU ? p.u : p.v]
            let count = max(1,min(50,Int(max(0,length-3)/(32/25.4))+1))
            p.columns = longU ? count : 2;p.rows = longU ? 2 : count
            p.pitch = SIMD2(repeating:32/25.4);p.spanU = !longU;p.spanV = longU
        } else {
            p.name = "Hinge cups · 35 mm";p.diameter = 35/25.4
            p.margin = longU ? SIMD2(3,22.5/25.4) : SIMD2(22.5/25.4,3)
            p.columns = longU ? 2 : 1;p.rows = longU ? 1 : 2;p.spanU = longU;p.spanV = !longU
        }
        return p
    }
}

enum ReliefRecipe {
    static func preview(_ source: Project,partID: UUID,style: ReliefStyle,diameter: Double) throws -> ParameterPreview {
        guard diameter.isFinite,diameter > 0,style != .none,let i = source.parts.firstIndex(where: { $0.id == partID }) else { throw ModelValidation.Failure(message:"Select a part and a positive cutter diameter.") }
        var candidate = source,count = 0
        for j in candidate.parts[i].cuts.indices where !candidate.parts[i].cuts[j].additive && candidate.parts[i].cuts[j].suppressed != true {
            let relief = CornerRelief(style:style,diameter:diameter)
            if let mate = candidate.parts[i].cuts[j].mateID,let k = candidate.studio?.matingJoints?.firstIndex(where: { $0.id == mate }) { candidate.studio!.matingJoints![k].relief = relief }
            else { candidate.parts[i].cuts[j].relief = relief }
            count += 1
        }
        guard count > 0 else { throw ModelValidation.Failure(message:"This part has no active rectangular pockets. Add a dado or pocket first, then add relief.") }
        if let component = candidate.parts[i].component {
            for j in candidate.parts.indices where j != i && candidate.parts[j].component == component {
                let instance = candidate.parts[j]
                candidate.parts[j] = candidate.parts[i]
                candidate.parts[j].id = instance.id;candidate.parts[j].shopNumber = instance.shopNumber;candidate.parts[j].name = instance.name
                candidate.parts[j].origin = instance.origin;candidate.parts[j].rot = instance.rot;candidate.parts[j].bindings = instance.bindings
                candidate.parts[j].group = instance.group;candidate.parts[j].hidden = instance.hidden
            }
        }
        try Regeneration.rebuild(parts:&candidate.parts,links:candidate.links,studio:candidate.studio ?? StudioState())
        try ModelValidation.validate(candidate)
        return ParameterPreview(project:candidate,affected:candidate.parts.filter { p in source.parts.first { $0.id == p.id } != p }.map(\.id),conflicts:[],before:source)
    }
}
