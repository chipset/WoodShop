import Foundation

enum ProjectTemplates {
    static let cabinetParameters = [
        DesignParameter(name: "cabinet_width", expression: "600mm"),
        DesignParameter(name: "cabinet_height", expression: "720mm"),
        DesignParameter(name: "cabinet_depth", expression: "300mm"),
        DesignParameter(name: "thickness", expression: "18mm"),
        DesignParameter(name: "back_thickness", expression: "6mm"),
        DesignParameter(name: "dado_depth", expression: "thickness / 3"),
        DesignParameter(name: "bottom_height", expression: "70mm"),
        DesignParameter(name: "shelf_height", expression: "cabinet_height / 2")
    ]
    static func mergedParameters(_ existing: [DesignParameter]) -> [DesignParameter] {
        existing + cabinetParameters.filter { p in !existing.contains { $0.name.lowercased() == p.name } }
    }
    static func bookcase(parameters: [DesignParameter], group: String) throws -> [Part] {
        let values = try Parametric.values(parameters)
        func binding(_ target: BindingTarget, _ axis: Int, _ expression: String, feature: UUID? = nil) -> DesignBinding {
            DesignBinding(target: target, axis: axis, feature: feature, expression: expression)
        }
        var result: [Part] = []
        let levels = ["bottom_height", "shelf_height", "cabinet_height - thickness"]
        for right in [false,true] {
            var part = Part(name: right ? "Right side" : "Left side", origin: .zero, size: SIMD3(repeating: 1), species: .plywood)
            part.thicknessAxis = 0; part.grainDirection = 1; part.group = group; part.cncTopPositive = !right
            part.bindings = [binding(.size,0,"thickness"),binding(.size,1,"cabinet_height"),binding(.size,2,"cabinet_depth")]
            if right { part.bindings!.append(binding(.position,0,"cabinet_width - thickness")) }
            for level in levels {
                let cut = Cut(kind:"Dado",lo:SIMD3(0,0,0),hi:SIMD3(1,1,values["cabinet_depth"]!.value),faceAxis:0,facePositive:!right,runAxis:2)
                part.cuts.append(cut)
                part.bindings! += [binding(.cutDepth,0,"dado_depth",feature:cut.id), binding(.cutWidth,0,"thickness",feature:cut.id),binding(.cutOffset,0,level,feature:cut.id)]
            }
            try Parametric.apply(to: &part,values:values); result.append(part)
        }
        for (i,level) in levels.enumerated() {
            var part = Part(name:["Bottom","Shelf","Top"][i],origin:.zero,size:SIMD3(repeating:1),species:.plywood)
            part.thicknessAxis = 1; part.grainDirection = 0; part.group = group
            part.bindings = [binding(.size,0,"cabinet_width - 2 * thickness + 2 * dado_depth"),binding(.size,1,"thickness"),binding(.size,2,"cabinet_depth"),binding(.position,0,"thickness - dado_depth"),binding(.position,1,level)]
            try Parametric.apply(to: &part,values:values); result.append(part)
        }
        var back = Part(name:"Back",origin:.zero,size:SIMD3(repeating:1),species:.plywood)
        back.thicknessAxis = 2; back.grainDirection = 1; back.group = group
        back.bindings = [binding(.size,0,"cabinet_width - 2 * thickness"),binding(.size,1,"cabinet_height - bottom_height - thickness"),binding(.size,2,"back_thickness"),binding(.position,0,"thickness"),binding(.position,1,"bottom_height + thickness"),binding(.position,2,"cabinet_depth")]
        try Parametric.apply(to:&back,values:values); result.append(back)
        return result
    }
}
extension Document {
    func insertParametricBookcase() {
        let success = transaction {
            let parameters = ProjectTemplates.mergedParameters(studio.parameters ?? [])
            let group = nextName("Bookcase")
            let additions = try ProjectTemplates.bookcase(parameters:parameters,group:group)
            studio.parameters = parameters; parts += additions
            selection = additions.first?.id; selectedIDs = Set(additions.map(\.id))
        }
        if success {
            recordHistory("Create parametric bookcase")
            status = "Bookcase dimensions and dado joints are driven by named parameters. Open Parameters & History to resize it."
        }
    }
}
