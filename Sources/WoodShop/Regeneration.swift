import Foundation

struct DesignConflict: Identifiable {
    var id = UUID()
    var part: UUID?
    var feature: FeatureRef?
    var message: String
}
struct FeatureRegenerationError: LocalizedError {
    var part: UUID
    var feature: FeatureRef
    var partName: String
    var featureName: String
    var reason: String
    var errorDescription: String? { "\(partName) · \(featureName): \(reason) Edit this feature or its driving parameter, then retry." }
}
struct ParameterPreview {
    var project: Project?
    var affected: [UUID]
    var conflicts: [DesignConflict]
    var before: Project
    var canApply: Bool { project != nil && conflicts.isEmpty }
}
enum Regeneration {
    static func rebuild(parts: inout [Part], links: [DimensionLink], studio: StudioState, applyParameters: Bool = false) throws {
        for part in parts { if let message = ModelValidation.axes(part) { throw ModelValidation.Failure(message:part.name + ": " + message) } }
        let values = try Parametric.values(studio.parameters ?? [])
        if applyParameters { for i in parts.indices { try Parametric.apply(to:&parts[i],values:values,validate:false) } }
        var remaining = Set(parts.map(\.id)), order: [UUID] = []
        while !remaining.isEmpty {
            let roots = remaining.filter { id in !links.contains { $0.target == id && remaining.contains($0.source) } }
            guard !roots.isEmpty else { throw ModelValidation.Failure(message:"Dimension links contain a cycle.") }
            order += roots; remaining.subtract(roots)
        }
        for id in order {
            guard let source = parts.first(where: { $0.id == id }) else { continue }
            for link in links where link.source == id {
                guard (0..<3).contains(link.sourceAxis),(0..<3).contains(link.targetAxis),let j = parts.firstIndex(where: { $0.id == link.target }) else { throw ModelValidation.Failure(message:"Invalid linked dimension.") }
                let value = source.size[link.sourceAxis] + link.offset
                guard value.isFinite,value >= 1 / 32 else { throw ModelValidation.Failure(message:parts[j].name + ": linked size must be at least 1/32 inch.") }
                if abs(parts[j].size[link.targetAxis] - value) > 1e-12 { let old = parts[j]; parts[j].size[link.targetAxis] = value; parts[j].adjustJoinery(from:old) }
            }
        }
        try AssemblyRelations.validateDrivers(parts:parts,relations:studio.relations ?? [],joints:studio.matingJoints ?? [])
        try AssemblyRelations.rebuild(&parts,relations:studio.relations ?? [],values:values)
        try MatingJoinery.regenerate(parts:&parts,joints:studio.matingJoints ?? [])
        for i in parts.indices {
            var pending = Set((parts[i].operations ?? []).indices.filter { parts[i].operations![$0].sketch != nil })
            while !pending.isEmpty {
                let pendingIDs = Set(pending.map { parts[i].operations![$0].id })
                let ready = pending.filter { j in parts[i].operations![j].sketch?.concentricWith.map { !pendingIDs.contains($0) } ?? true }
                guard !ready.isEmpty else { throw ModelValidation.Failure(message:parts[i].name+": concentric sketch references contain a cycle. Remove one reference.") }
                for j in ready {
                    let op = parts[i].operations![j]
                    do { parts[i].operations![j] = try op.sketch!.generated(from:op,size:parts[i].size,values:values,references:parts[i].operations ?? []) }
                    catch { throw FeatureRegenerationError(part:parts[i].id,feature:FeatureRef(part:parts[i].id,kind:.operation,feature:op.id),partName:parts[i].name,featureName:op.name,reason:error.localizedDescription) }
                }
                pending.subtract(ready)
            }
            for j in (parts[i].patterns ?? []).indices {
                do { try parts[i].patterns![j].evaluate(values) }
                catch { let pattern = parts[i].patterns![j];throw FeatureRegenerationError(part:parts[i].id,feature:FeatureRef(part:parts[i].id,kind:.pattern,feature:pattern.id),partName:parts[i].name,featureName:pattern.name,reason:error.localizedDescription) }
            }
            if parts[i].featureOrder != nil || !(parts[i].patterns ?? []).isEmpty || parts[i].cuts.contains(where: { $0.mateID != nil }) { parts[i].featureOrder = parts[i].featureSteps }
            do { try FeatureReplay.validate(parts[i]) }
            catch { throw ModelValidation.Failure(message:parts[i].name+": "+error.localizedDescription+" Inspect the feature order and highlighted operation.") }
            try Parametric.validateBindings(parts[i],values:values)
        }
    }
    static func preview(_ source: Project, parameters: [DesignParameter]) -> ParameterPreview {
        var candidate = source
        if candidate.studio == nil { candidate.studio = StudioState() }
        candidate.studio!.parameters = parameters
        var conflicts: [DesignConflict] = []
        let values: [String:Quantity]
        do { values = try Parametric.values(parameters) }
        catch { return ParameterPreview(project:nil,affected:[],conflicts:[DesignConflict(message:error.localizedDescription)],before:source) }
        for i in candidate.parts.indices {
            do { try Parametric.apply(to:&candidate.parts[i],values:values,validate:false) }
            catch { conflicts.append(DesignConflict(part:candidate.parts[i].id,message:candidate.parts[i].name + ": " + error.localizedDescription)) }
        }
        do { try rebuild(parts:&candidate.parts,links:candidate.links,studio:candidate.studio!) }
        catch {
            let message = error.localizedDescription
            let featureError = error as? FeatureRegenerationError
            let matching = candidate.parts.first { message.hasPrefix($0.name + ":") || message.hasPrefix($0.name + ",") }
            conflicts.append(DesignConflict(part:featureError?.part ?? matching?.id,feature:featureError?.feature,message:message))
        }
        // Collect part-specific conflicts instead of hiding every issue behind the first failure.
        for part in candidate.parts {
            if let error = ModelValidation.part(part),!conflicts.contains(where: { $0.part == part.id && $0.message.contains(error) }) {
                conflicts.append(DesignConflict(part:part.id,message:part.name + ": " + error))
            }
        }
        if conflicts.isEmpty { do { try ModelValidation.validate(candidate) } catch { conflicts.append(DesignConflict(message:error.localizedDescription)) } }
        let affected = candidate.parts.filter { part in source.parts.first { $0.id == part.id } != part }.map(\.id)
        return ParameterPreview(project:conflicts.isEmpty ? candidate : nil,affected:affected,conflicts:conflicts,before:source)
    }
}
extension Document {
    @discardableResult func savePattern(_ pattern: DrillingPattern, partID: UUID) -> Bool {
        transaction {
            guard let i = parts.firstIndex(where: { $0.id == partID }) else { throw ModelValidation.Failure(message:"The part was removed.") }
            var patterns = parts[i].patterns ?? []
            if let j = patterns.firstIndex(where: { $0.id == pattern.id }) { patterns[j] = pattern } else { patterns.append(pattern) }
            parts[i].patterns = patterns
            parts[i].featureOrder = parts[i].featureSteps
            if let component = parts[i].component {
                let definitions = parts[i].patterns, order = parts[i].featureOrder
                for j in parts.indices where j != i && parts[j].component == component {
                    parts[j].patterns = definitions; parts[j].featureOrder = order
                }
            }
        }
    }
    func explodePattern(_ ref: FeatureRef) {
        transaction {
            guard let i = parts.firstIndex(where: { $0.id == ref.part }),let pattern = parts[i].patterns?.first(where: { $0.id == ref.feature }) else { return }
            var operations = try pattern.generated(size:parts[i].size)
            for j in operations.indices { operations[j].patternID = nil }
            let step = FeatureStep(kind:.pattern,feature:ref.feature)
            var order = parts[i].featureSteps
            if let index = order.firstIndex(of:step) { order.replaceSubrange(index...index,with:operations.map { FeatureStep(kind:.operation,feature:$0.id) }) }
            parts[i].patterns?.removeAll { $0.id == ref.feature }
            parts[i].operations = (parts[i].operations ?? []) + operations; parts[i].featureOrder = order
        }
    }
    @discardableResult func createMatingJoint(_ joint: MatingJoint) -> Bool {
        transaction {
            var joint = joint
            joint.number = ((studio.matingJoints ?? []).compactMap(\.number).max() ?? 0) + 1
            for i in parts.indices where parts[i].id == joint.shelf || parts[i].id == joint.receiver { parts[i].component = nil }
            studio.matingJoints = (studio.matingJoints ?? []) + [joint]
        }
    }
    func useParameterPreview(_ parameters: [DesignParameter]) -> ParameterPreview {
        let report = Regeneration.preview(project,parameters:parameters)
        parameterPreview = report.canApply && !report.affected.isEmpty ? report.project : nil
        previewAffected = Set(report.affected)
        previewConflicts = Set(report.conflicts.compactMap(\.part))
        return report
    }
    func clearParameterPreview() { parameterPreview = nil; previewAffected = []; previewConflicts = [] }
    func selectFeature(_ ref: FeatureRef) {
        select(ref.part); selectedFeature = ref
        if let part = part(ref.part) { status = part.featureName(FeatureStep(kind:ref.kind,feature:ref.feature)) + " · " + ShopIdentity.label(part) + " " + part.name }
    }
    func reorderFeature(_ ref: FeatureRef, delta: Int) {
        edit(ref.part) { p in var steps = p.featureSteps; if let i = steps.firstIndex(of:FeatureStep(kind:ref.kind,feature:ref.feature)),steps.indices.contains(i + delta) { steps.swapAt(i,i + delta) }; p.featureOrder = steps }
    }
    func resumeFeatureHistory() { historyInspection = nil }
}

extension Document {
    func prepareForExport() -> Bool {
        finishDrag?()
        if faceSketchEditorActive { status = "Apply or cancel the face sketch before exporting.";return false }
        if parameterPreview != nil { status = "Apply or discard the parameter preview before exporting."; return false }
        if historyInspection != nil { status = "Resume the full feature history before exporting."; return false }
        return true
    }
}

extension Document {
    func replicateMates(_ mapping:[UUID:UUID],reflectLocalX:Bool = false) {
        let original = studio.matingJoints ?? []
        var newJoints: [MatingJoint] = [],mateMap: [UUID:MatingJoint] = [:]
        var number = (original.compactMap(\.number).max() ?? 0)+1
        for old in original {
            guard let shelf = mapping[old.shelf],let receiver = mapping[old.receiver] else { continue }
            var joint = old; joint.id = UUID(); joint.shelf = shelf; joint.receiver = receiver; joint.number = number; number += 1
            if reflectLocalX && joint.axis == 0 { joint.positive.toggle() }
            newJoints.append(joint); mateMap[old.id] = joint
        }
        for id in mapping.values {
            guard let i = parts.firstIndex(where: { $0.id == id }) else { continue }
            for j in parts[i].cuts.indices {
                guard let mate = parts[i].cuts[j].mateID else { continue }
                let oldID = parts[i].cuts[j].id
                if let replacement = mateMap[mate] {
                    parts[i].cuts[j].mateID = replacement.id; parts[i].cuts[j].id = replacement.cutID
                    parts[i].cuts[j].name = replacement.label + " · " + replacement.name
                    parts[i].featureOrder = parts[i].featureOrder?.map { step in step.kind == .cut && step.feature == oldID ? FeatureStep(kind:.cut,feature:replacement.cutID) : step }
                    for k in (parts[i].bindings ?? []).indices where parts[i].bindings![k].feature == oldID { parts[i].bindings![k].feature = replacement.cutID }
                } else { parts[i].cuts[j].mateID = nil }
            }
        }
        if !newJoints.isEmpty { studio.matingJoints = original+newJoints }
    }
}
