import Foundation

struct FaceSketchRequest: Identifiable {
    var id = UUID()
    var part: UUID
    var axis: Int
    var positive: Bool
}

enum FaceSketchEditing {
    static func preview(_ source: Project,partID: UUID,operation: MachiningOperation,values: FaceSketch,toolID: UUID? = nil,replaceToolAssignment: Bool = false) throws -> ParameterPreview {
        guard let index = source.parts.firstIndex(where: { $0.id == partID }),source.parts[index].hardware != true,
              source.parts[index].mesh == nil,(0..<3).contains(operation.axis) else { throw ModelValidation.Failure(message:"Choose an outer flat face of a woodworking part. General mesh surfaces are not supported by face sketches.") }
        var candidate = source,op = operation
        if let profile = candidate.parts[index].profile,profile.thickness != op.axis { throw ModelValidation.Failure(message:"On a curved panel, sketch on its front or back flat face. Curved perimeter faces need a separate 3D strategy.") }
        if let toolID,source.studio?.setupProfile?.tools.contains(where: { $0.id == toolID }) != true { throw ModelValidation.Failure(message:"This cutter is missing from the CNC setup. Choose Setup default or an available cutter.") }
        if replaceToolAssignment || toolID != nil {
            if candidate.parts[index].toolAssignments == nil,toolID != nil { candidate.parts[index].toolAssignments = [:] }
            candidate.parts[index].toolAssignments?[op.id.uuidString] = toolID
        }
        op.sketch = values
        op = try values.generated(from:op,size:candidate.parts[index].size,values:Parametric.values(source.studio?.parameters ?? []),references:candidate.parts[index].operations ?? [])
        if candidate.parts[index].operations == nil { candidate.parts[index].operations = [] }
        if let j = candidate.parts[index].operations!.firstIndex(where: { $0.id == op.id }) { candidate.parts[index].operations![j] = op }
        else { candidate.parts[index].operations!.append(op) }
        candidate.parts[index].featureOrder = candidate.parts[index].featureSteps
        if let component = candidate.parts[index].component {
            for i in candidate.parts.indices where i != index && candidate.parts[i].component == component {
                if replaceToolAssignment || toolID != nil {
                    if candidate.parts[i].toolAssignments == nil,toolID != nil { candidate.parts[i].toolAssignments = [:] }
                    candidate.parts[i].toolAssignments?[op.id.uuidString] = toolID
                }
                candidate.parts[i].operations = candidate.parts[index].operations
                candidate.parts[i].featureOrder = candidate.parts[index].featureOrder
            }
        }
        try Regeneration.rebuild(parts:&candidate.parts,links:candidate.links,studio:candidate.studio ?? StudioState())
        try ModelValidation.validate(candidate)
        return ParameterPreview(project:candidate,affected:candidate.parts.filter { p in source.parts.first { $0.id == p.id } != p }.map(\.id),conflicts:[],before:source)
    }
    /// A conservative stock test for sketch boundaries on an extruded curved panel.
    static func insideProfile(_ op: MachiningOperation,part: Part) -> Bool {
        guard let profile = part.profile,profile.thickness == op.axis else { return true }
        let boundary = profile.contour(size:part.size)
        func toProfile(_ p: SIMD2<Double>) -> SIMD2<Double> { profile.u == op.u ? p : SIMD2(p.y,p.x) }
        func contains(_ p: SIMD2<Double>) -> Bool {
            if GeometryImport.contains(p,polygon:boundary) { return true }
            return boundary.indices.contains { i in
                let a = boundary[i],d = boundary[(i+1)%boundary.count]-a,denom = d.x*d.x+d.y*d.y
                let t = denom>0 ? max(0,min(1,((p.x-a.x)*d.x+(p.y-a.y)*d.y)/denom)) : 0
                let delta = p-(a+d*t);return delta.x*delta.x+delta.y*delta.y<1e-12
            }
        }
        for i in op.contour.indices {
            let a = toProfile(op.contour[i]),b = toProfile(op.contour[(i+1)%op.contour.count])
            guard contains(a),contains((a+b)/2) else { return false }
            for j in boundary.indices {
                let c = boundary[j],d = boundary[(j+1)%boundary.count],denom = Planar.cross(b-a,d-c)
                if abs(denom)>1e-12 {
                    let t = Planar.cross(c-a,d-c)/denom,u = Planar.cross(c-a,b-a)/denom
                    if t>1e-8,t<1-1e-8,u>1e-8,u<1-1e-8 { return false }
                }
            }
        }
        return true
    }
}

extension Document {
    func beginFaceSketch() {
        guard let part = selectedPart,part.hardware != true,part.mesh == nil,!workspaceInspectionOnly else { return }
        finishDrag?()
        let face = selectedFace?.part == part.id ? selectedFace : nil
        faceSketchRequest = FaceSketchRequest(part:part.id,axis:face?.axis ?? part.materialAxes.t,positive:face?.positive ?? part.cncTopPositive ?? true)
    }
}
