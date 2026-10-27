import Foundation

struct DimensionRequest: Identifiable {
    var part: UUID
    var axis: Int
    var id: String { part.uuidString+String(axis) }
}

enum DimensionChange {
    static func driver(_ source: Project,_ request: DimensionRequest) -> String? {
        if let binding = source.parts.first(where: { $0.id == request.part })?.bindings?.first(where: { $0.target == .size && $0.axis == request.axis }) { return binding.expression }
        if let link = source.links.first(where: { $0.target == request.part && $0.targetAxis == request.axis }) {
            return "Linked to " + (source.parts.first { $0.id == link.source }?.name ?? "another part")
        }
        return nil
    }
    static func preview(_ source: Project,request: DimensionRequest,text: String) throws -> ParameterPreview {
        guard (0..<3).contains(request.axis),let index = source.parts.firstIndex(where: { $0.id == request.part }),
              let value = Units.parse(text,bareIsMM:source.metric),value >= 1/32 else { throw ModelValidation.Failure(message:"Enter a size of at least 1/32 inch, such as 24 1/2\" or 622 mm.") }
        if let expression = driver(source,request) {
            guard var definitions = source.studio?.parameters,let i = definitions.firstIndex(where: { $0.name.lowercased() == expression.trimmingCharacters(in:.whitespaces).lowercased() }) else {
                throw ModelValidation.Failure(message:"This size follows ‘\(expression)’. Open Parameters to edit its driving dimensions.")
            }
            definitions[i].expression = String(value)+"in"
            return Regeneration.preview(source,parameters:definitions)
        }
        var candidate = source
        let original = candidate.parts[index]
        candidate.parts[index].size[request.axis] = value;candidate.parts[index].adjustJoinery(from:original)
        if let component = original.component {
            for i in candidate.parts.indices where i != index && candidate.parts[i].component == component {
                let instance = candidate.parts[i]
                candidate.parts[i] = candidate.parts[index]
                candidate.parts[i].id = instance.id;candidate.parts[i].shopNumber = instance.shopNumber;candidate.parts[i].name = instance.name
                candidate.parts[i].origin = instance.origin;candidate.parts[i].rot = instance.rot;candidate.parts[i].bindings = instance.bindings
                candidate.parts[i].group = instance.group;candidate.parts[i].hidden = instance.hidden
            }
        }
        try Regeneration.rebuild(parts:&candidate.parts,links:candidate.links,studio:candidate.studio ?? StudioState())
        try ModelValidation.validate(candidate)
        return ParameterPreview(project:candidate,affected:candidate.parts.filter { p in source.parts.first { $0.id == p.id } != p }.map(\.id),conflicts:[],before:source)
    }
}

extension Document {
    @discardableResult func applyDimensionPreview(_ preview: ParameterPreview,historyTitle: String = "Edit dimension") -> Bool {
        guard preview.before == project,let candidate = preview.project,preview.canApply else { status = "The design changed. Preview this dimension again before applying it.";return false }
        clearParameterPreview()
        let success = transaction { parts = candidate.parts;studio = candidate.studio ?? StudioState() }
        if success { recordHistory(historyTitle);status = "Updated design and regenerated \(preview.affected.count) part(s)." }
        return success
    }
    @discardableResult func setFeatureSuppressed(_ ref: FeatureRef,_ suppressed: Bool) -> Bool {
        guard !workspaceInspectionOnly else { status = "Resume full history before changing a feature.";return false }
        return transaction {
            guard let i = parts.firstIndex(where: { $0.id == ref.part }) else { throw ModelValidation.Failure(message:"The part was removed.") }
            switch ref.kind {
            case .cut:
                guard let j = parts[i].cuts.firstIndex(where: { $0.id == ref.feature }) else { return }
                if let mate = parts[i].cuts[j].mateID,let k = studio.matingJoints?.firstIndex(where: { $0.id == mate }) { studio.matingJoints![k].suppressed = suppressed }
                else { parts[i].cuts[j].suppressed = suppressed }
            case .operation: if let j = parts[i].operations?.firstIndex(where: { $0.id == ref.feature }) { parts[i].operations![j].suppressed = suppressed }
            case .pattern: if let j = parts[i].patterns?.firstIndex(where: { $0.id == ref.feature }) { parts[i].patterns![j].suppressed = suppressed }
            case .trim: if let j = parts[i].trims.firstIndex(where: { $0.id == ref.feature }) { parts[i].trims[j].suppressed = suppressed }
            }
            if !applyPartChanges([parts[i]]) { throw ModelValidation.Failure(message:status) }
        }
    }
}

extension Part {
    func featureSuppressed(_ step: FeatureStep) -> Bool {
        switch step.kind {
        case .cut: return cuts.first { $0.id == step.feature }?.suppressed == true
        case .operation: return operations?.first { $0.id == step.feature }?.suppressed == true
        case .pattern: return patterns?.first { $0.id == step.feature }?.suppressed == true
        case .trim: return trims.first { $0.id == step.feature }?.suppressed == true
        }
    }
}

enum WoodworkingPreset: String,CaseIterable,Identifiable {
    case cabinet = "Cabinet / bookcase",drawer = "Drawer box",shelf = "Shelf",bench = "Workbench"
    var id: String { rawValue }
    var groupName: String { self == .cabinet ? "Cabinet" : rawValue }
    var parameterStem: String { switch self { case .cabinet:return "cabinet";case .drawer:return "drawer";case .shelf:return "shelf";case .bench:return "workbench" } }
}

struct PresetDimensions {
    var width = 30.0
    var height = 34.5
    var depth = 23.25
    var thickness = 0.75
    var backThickness = 0.25
    var clearance = 0.5
    var inset = 0.375
}

enum PresetBuilder {
    /// Each inserted assembly receives its own parameter namespace.
    static func build(_ kind: WoodworkingPreset,dimensions d: PresetDimensions,prefix: String,group: String) throws -> (parts:[Part],parameters:[DesignParameter]) {
        guard [d.width,d.height,d.depth,d.thickness,d.backThickness,d.clearance,d.inset].allSatisfy({ $0.isFinite && $0 >= 0 }),
              d.thickness >= 1/32,d.backThickness >= 1/32 else { throw ModelValidation.Failure(message:"Use positive stock thickness and finite, nonnegative dimensions.") }
        let fits: Bool
        switch kind {
        case .cabinet: fits = d.width > 2*d.thickness && d.height > 2*d.thickness && d.depth > d.backThickness+d.inset
        case .drawer: fits = d.width > 2*d.thickness+2*d.clearance && d.depth > 2*d.thickness && d.height > d.inset+d.backThickness
        case .shelf: fits = d.width > 2*d.clearance && d.depth >= 1/32
        case .bench: fits = d.width > 4*d.thickness && d.depth > 4*d.thickness && d.height > 8*d.thickness/3
        }
        guard fits else { throw ModelValidation.Failure(message:"The opening must leave room for material thickness, clearance, and the inset. Increase the outside dimensions or reduce the allowances.") }
        let values: [(String,Double)] = [("width",d.width),("height",d.height),("depth",d.depth),("thickness",d.thickness),("back",d.backThickness),("clearance",d.clearance),("inset",d.inset)]
        let definitions = values.map { DesignParameter(name:prefix+"_"+$0.0,expression:String($0.1)+"in") }
        let evaluated = try Parametric.values(definitions)
        var parts: [Part] = []
        func e(_ text: String) -> String {
            var result = text
            for key in values.map(\.0).sorted(by: { $0.count > $1.count }) { result = result.replacingOccurrences(of:"\\b"+key+"\\b",with:prefix+"_"+key,options:.regularExpression) }
            return result
        }
        func board(_ name: String,_ position: [String],_ size: [String],_ thickness: Int,_ grain: Int) throws {
            var p = Part(name:name,origin:.zero,size:SIMD3(repeating:1),species:.plywood)
            p.group = group;p.thicknessAxis = thickness;p.grainDirection = grain
            p.bindings = (0..<3).map { DesignBinding(target:.size,axis:$0,expression:e(size[$0])) } + (0..<3).map { DesignBinding(target:.position,axis:$0,expression:e(position[$0])) }
            try Parametric.apply(to:&p,values:evaluated);parts.append(p)
        }
        switch kind {
        case .cabinet:
            try board("Left side",["0in","0in","0in"],["thickness","height","depth"],0,1)
            try board("Right side",["width-thickness","0in","0in"],["thickness","height","depth"],0,1)
            for (name,y) in [("Bottom","0in"),("Shelf","height/2"),("Top","height-thickness")] {
                try board(name,["thickness",y,"0in"],["width-2*thickness","thickness","depth"],1,0)
            }
            try board("Inset back",["thickness","thickness","depth-back-inset"],["width-2*thickness","height-2*thickness","back"],2,1)
            // Shelves stop at the inset back so assembled stock does not overlap it.
            for i in parts.indices where parts[i].thicknessAxis == 1 {
                if let b = parts[i].bindings?.firstIndex(where: { $0.target == .size && $0.axis == 2 }) { parts[i].bindings![b].expression = e("depth-back-inset");try Parametric.apply(to:&parts[i],values:evaluated) }
            }
        case .drawer:
            try board("Left drawer side",["clearance","0in","0in"],["thickness","height","depth"],0,2)
            try board("Right drawer side",["width-clearance-thickness","0in","0in"],["thickness","height","depth"],0,2)
            try board("Drawer front",["clearance+thickness","0in","0in"],["width-2*clearance-2*thickness","height","thickness"],2,0)
            try board("Drawer back",["clearance+thickness","0in","depth-thickness"],["width-2*clearance-2*thickness","height","thickness"],2,0)
            try board("Inset drawer bottom",["clearance+thickness","inset","thickness"],["width-2*clearance-2*thickness","back","depth-2*thickness"],1,0)
        case .shelf:
            try board("Shelf",["clearance","0in","0in"],["width-2*clearance","thickness","depth"],1,0)
        case .bench:
            try board("Workbench top",["0in","height-thickness","0in"],["width","thickness","depth"],1,0)
            for (name,x,z) in [("Front left leg","0in","0in"),("Front right leg","width-2*thickness","0in"),("Back left leg","0in","depth-2*thickness"),("Back right leg","width-2*thickness","depth-2*thickness")] {
                try board(name,[x,"0in",z],["2*thickness","height-thickness","2*thickness"],0,1)
            }
            try board("Lower shelf",["2*thickness","height/4","2*thickness"],["width-4*thickness","thickness","depth-4*thickness"],1,0)
        }
        for p in parts { if let message = ModelValidation.part(p) { throw ModelValidation.Failure(message:message) } }
        return (parts,definitions)
    }
}

extension Document {
    @discardableResult func insertPreset(_ kind: WoodworkingPreset,dimensions: PresetDimensions) -> Bool {
        guard !workspaceInspectionOnly else { return false }
        var ordinal = 1
        while (studio.parameters ?? []).contains(where: { $0.name.hasPrefix(kind.parameterStem+"_\(ordinal)_") }) { ordinal += 1 }
        let prefix = kind.parameterStem+"_\(ordinal)"
        let result = transaction {
            let built = try PresetBuilder.build(kind,dimensions:dimensions,prefix:prefix,group:nextName(kind.groupName))
            studio.parameters = (studio.parameters ?? [])+built.parameters
            parts += built.parts;selection = built.parts.first?.id;selectedIDs = Set(built.parts.map(\.id))
        }
        if result { recordHistory("Create "+kind.rawValue);status = "Created \(kind.rawValue). Dimensions are linked to its own named parameters." }
        return result
    }
}

enum CNCJobScope {
    static func project(_ source: Project,ids: Set<UUID>?) -> Project {
        guard let ids else { return source }
        var result = source;result.parts = source.parts.filter { ids.contains($0.id) && $0.hardware != true }
        let included = Set(result.parts.map(\.id))
        result.studio?.relations = source.studio?.relations?.filter { included.contains($0.source) && included.contains($0.target) }
        result.links = result.links.filter { included.contains($0.source) && included.contains($0.target) }
        let joints = result.studio?.matingJoints?.filter { included.contains($0.shelf) && included.contains($0.receiver) }
        result.studio?.matingJoints = joints
        let mates = Set((result.studio?.matingJoints ?? []).map(\.id))
        for i in result.parts.indices { for j in result.parts[i].cuts.indices {
            if let mate = result.parts[i].cuts[j].mateID,!mates.contains(mate) { result.parts[i].cuts[j].mateID = nil }
        } }
        let steps = result.studio?.assemblySteps?.compactMap { step -> AssemblyStep? in
            var step = step;step.parts = step.parts.filter(included.contains);return step.parts.isEmpty ? nil : step
        }
        result.studio?.assemblySteps = steps
        result.studio?.history = nil;result.studio?.library = []
        return result
    }
}

extension Document {
    var cncProject: Project { CNCJobScope.project(project,ids:cncPartIDs) }
    func beginCNCJob() { cncPartIDs = nil;fabricationTab = 4;showCutList = true }
}
