import SwiftUI

struct ReceiverFaceDraft: Identifiable {
    var id = UUID()
    var part: UUID?
    var axis = 0
    var positive = true
}
struct MatingJointWizard: View {
    @ObservedObject var doc: Document
    @Environment(\.dismiss) private var dismiss
    @State private var shelf: UUID?
    @State private var receivers: [ReceiverFaceDraft] = []
    @State private var kind = MatingJointKind.dado
    @State private var depth = 0.25
    @State private var clearance = 0.005
    @State private var seat = true
    @State private var reliefStyle = ReliefStyle.none
    @State private var diameter = 0.25
    @State private var previewMessage = ""
    @State private var pending: [MatingJoint] = []
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Fit a shelf into receiving boards").font(.title2.bold())
            Text("Choose the shelf and one or two receiving faces. Joint width follows shelf thickness; joint position follows the shelf.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Picker("Shelf / inserted part",selection:$shelf) {
                        Text("Choose shelf").tag(nil as UUID?)
                        ForEach(doc.parts.filter { $0.hardware != true }) { Text(ShopIdentity.label($0) + " " + $0.name).tag(Optional($0.id)) }
                    }.onChange(of:shelf) { _,_ in guessFaces() }
                    ForEach($receivers) { $receiver in
                        GroupBox("Receiving board") {
                            VStack(alignment:.leading,spacing:8) {
                                Picker("Part",selection:$receiver.part) {
                                    Text("Choose receiving board").tag(nil as UUID?)
                                    ForEach(doc.parts.filter { $0.id != shelf && $0.hardware != true }) { Text(ShopIdentity.label($0) + " " + $0.name).tag(Optional($0.id)) }
                                }.onChange(of:receiver.part) { _,_ in guessFaces() }
                                AxisPicker(title:"Face normal",value:$receiver.axis)
                                Toggle("Positive face",isOn:$receiver.positive)
                            }.padding(8)
                        }
                    }
                    HStack {
                        Button("Add second receiving board") { receivers.append(ReceiverFaceDraft()) }.disabled(receivers.count >= 2)
                        if receivers.count > 1 { Button("Remove second board") { receivers.removeLast() } }
                    }
                    Picker("Joinery",selection:$kind) { ForEach(MatingJointKind.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    HStack {
                        DimField(label:"Pocket depth",value:$depth,metric:doc.metric,minimum:0.001)
                        DimField(label:"Fit clearance",value:$clearance,metric:doc.metric,minimum:0)
                    }
                    Toggle("Automatically fit shelf ends to the pocket floors",isOn:$seat)
                    Text("Automatic fitting preserves the opposite end when using one receiver and fits both ends with two. If the shelf's length/position is expression-driven, keep its dimensions or update the driving expressions first. Involved component instances become unique.").font(.caption).foregroundStyle(.secondary)
                    Picker("Corner relief",selection:$reliefStyle) { ForEach(ReliefStyle.allCases) { Text($0.rawValue).tag($0) } }
                    if reliefStyle != .none { DimField(label:"Cutter diameter",value:$diameter,metric:doc.metric,minimum:0.001) }
                    if !previewMessage.isEmpty { Text(previewMessage).foregroundStyle(doc.parameterPreview == nil ? Color.red : Color.secondary) }
                }.padding(4)
            }
            HStack {
                Button("Preview fit & joints") { preview() }
                Button("Discard preview") { doc.clearParameterPreview(); previewMessage = "" }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create linked joinery") {
                    let joints = definitions()
                    guard !joints.isEmpty else { previewMessage = "Choose a shelf and receiving board."; return }
                    doc.clearParameterPreview()
                    if doc.createMatingJoints(joints) { dismiss() } else { previewMessage = doc.status }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width:800,height:760).background(Color(nsColor:.windowBackgroundColor))
        .onAppear {
            let selected = doc.parts.filter { doc.selectedIDs.contains($0.id) }
            shelf = selected.first { $0.materialAxes.t == 1 && $0.id != doc.selectedFace?.part }?.id
                ?? selected.first { $0.id != doc.selectedFace?.part }?.id ?? doc.selection
            let targets = selected.filter { $0.id != shelf }
            receivers = targets.prefix(2).map { ReceiverFaceDraft(part:$0.id,axis:$0.materialAxes.t) }
            if receivers.isEmpty { receivers = [ReceiverFaceDraft()] }
            clearance = doc.studio.setupProfile?.clearance ?? 0.005
            diameter = doc.studio.setupProfile?.defaultTool?.diameter ?? 0.25
            seat = !(doc.part(shelf ?? UUID())?.bindings ?? []).contains { [.size,.position].contains($0.target) }
            guessFaces()
            if let p = receivers.first?.part.flatMap(doc.part) { depth = min(0.25,p.size[receivers[0].axis]/3) }
        }
        .onDisappear { doc.clearParameterPreview() }
    }
    private func guessFaces() {
        guard let source = shelf.flatMap(doc.part) else { return }
        for i in receivers.indices {
            if let part = receivers[i].part.flatMap(doc.part) {
                receivers[i].axis = part.materialAxes.t
                receivers[i].positive = part.toLocal(source.center)[receivers[i].axis] >= part.size[receivers[i].axis]/2
                if let face = doc.selectedFace,face.part == part.id { receivers[i].axis = face.axis; receivers[i].positive = face.positive }
            }
        }
    }
    private func definitions() -> [MatingJoint] {
        guard let shelf,doc.part(shelf) != nil else { return [] }
        return receivers.compactMap { face in
            guard let receiver = face.part,receiver != shelf else { return nil }
            return MatingJoint(name:(doc.part(shelf)?.name ?? "Shelf") + " → " + (doc.part(receiver)?.name ?? "Board"),shelf:shelf,receiver:receiver,axis:face.axis,positive:face.positive,
                depth:depth,clearance:clearance,kind:kind,autoSeat:seat,relief:reliefStyle == .none ? nil : CornerRelief(style:reliefStyle,diameter:diameter))
        }
    }
    private func preview() {
        pending = definitions()
        guard !pending.isEmpty else { previewMessage = "Choose a shelf and receiving board."; return }
        let report = doc.previewMatingJoints(pending,replace:false)
        previewMessage = report.canApply ? "Preview ready. \(report.affected.count) parts change; the original design is unchanged until you create the joints." : report.conflicts.map(\.message).joined(separator:"\n")
    }
}
struct MatingJointEditor: View {
    @ObservedObject var doc: Document
    @State private var draft: MatingJoint
    @State private var error = ""
    init(doc:Document,initial:MatingJoint) { self.doc = doc; _draft = State(initialValue:initial) }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(draft.label + " · Linked to " + (doc.part(draft.shelf)?.name ?? "removed shelf")).font(.headline)
            TextField("Joint name",text:$draft.name).textFieldStyle(.roundedBorder)
            Picker("Type",selection:$draft.kind) { ForEach(MatingJointKind.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            DimField(label:"Depth",value:$draft.depth,metric:doc.metric,minimum:0.001)
            DimField(label:"Fit clearance",value:$draft.clearance,metric:doc.metric,minimum:0)
            Toggle("Auto-fit shelf end",isOn:$draft.autoSeat)
            Toggle("Joint enabled",isOn:Binding(get: { !draft.suppressed },set: { draft.suppressed = !$0 }))
            Text("Width and position come from the shelf. Edit the shelf or its driving parameters to change them.").font(.caption).foregroundStyle(.secondary)
            Picker("Relief",selection:Binding(get: { draft.relief?.style ?? .none },set: { style in draft.relief = style == .none ? nil : CornerRelief(style:style,diameter:draft.relief?.diameter ?? doc.studio.setupProfile?.defaultTool?.diameter ?? 0.25) })) {
                ForEach(ReliefStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            if draft.relief != nil { DimField(label:"Cutter diameter",value:Binding(get: { draft.relief?.diameter ?? 0.25 },set: { draft.relief?.diameter = $0 }),metric:doc.metric,minimum:0.001) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Preview") {
                    let report = doc.previewMatingJoints([draft],replace:true)
                    error = report.canApply ? "" : report.conflicts.map(\.message).joined(separator:"\n")
                }
                Button("Apply linked joint") {
                    doc.clearParameterPreview()
                    if !doc.transaction({ if let i = doc.studio.matingJoints?.firstIndex(where: { $0.id == draft.id }) { doc.studio.matingJoints![i] = draft } }) { error = doc.status }
                }.buttonStyle(.borderedProminent)
                Button("Remove link & cut",role:.destructive) { doc.transaction { doc.studio.matingJoints?.removeAll { $0.id == draft.id } } }
            }
        }
    }
}
extension Document {
    @discardableResult func createMatingJoints(_ joints: [MatingJoint]) -> Bool {
        transaction {
            guard Set(joints.map(\.receiver)).count == joints.count else { throw ModelValidation.Failure(message:"Choose distinct receiving boards.") }
            var saved = studio.matingJoints ?? [],number = (saved.compactMap(\.number).max() ?? 0) + 1
            for var joint in joints {
                joint.number = number; number += 1
                for i in parts.indices where parts[i].id == joint.shelf || parts[i].id == joint.receiver { parts[i].component = nil }
                saved.append(joint)
            }
            studio.matingJoints = saved
        }
    }
    func previewMatingJoints(_ joints: [MatingJoint],replace: Bool) -> ParameterPreview {
        var candidate = project
        if candidate.studio == nil { candidate.studio = StudioState() }
        var saved = candidate.studio!.matingJoints ?? []
        for joint in joints {
            if replace,let i = saved.firstIndex(where: { $0.id == joint.id }) { saved[i] = joint } else { saved.append(joint) }
            for i in candidate.parts.indices where candidate.parts[i].id == joint.shelf || candidate.parts[i].id == joint.receiver { candidate.parts[i].component = nil }
        }
        candidate.studio!.matingJoints = saved
        let report = Regeneration.preview(candidate,parameters:candidate.studio?.parameters ?? [])
        let affected = (report.project?.parts ?? []).filter { part in self.parts.first { $0.id == part.id } != part }.map(\.id)
        parameterPreview = report.canApply ? report.project : nil; previewAffected = Set(affected); previewConflicts = Set(report.conflicts.compactMap(\.part))
        return ParameterPreview(project:report.project,affected:affected,conflicts:report.conflicts,before:project)
    }
}
