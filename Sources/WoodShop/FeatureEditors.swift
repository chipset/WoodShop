import SwiftUI

struct FeatureEditorSheet: View {
    @ObservedObject var doc: Document
    let reference: FeatureRef
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if reference.kind == .operation,let op = doc.part(reference.part)?.operations?.first(where: { $0.id == reference.feature }),op.sketch != nil {
            FaceSketchEditor(doc:doc,partID:reference.part,initial:op)
        } else { legacyEditor }
    }
    private var legacyEditor: some View {
        VStack(alignment:.leading,spacing:12) {
            if let part = doc.part(reference.part) {
                Text(ShopIdentity.label(part) + " · " + part.featureName(FeatureStep(kind:reference.kind,feature:reference.feature))).font(.title2.bold())
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        switch reference.kind {
                        case .pattern:
                            if let pattern = part.patterns?.first(where: { $0.id == reference.feature }) { PatternEditor(doc:doc,partID:part.id,initial:pattern) }
                        case .cut:
                            if let cut = part.cuts.first(where: { $0.id == reference.feature }) {
                                if let id = cut.mateID,let joint = doc.studio.matingJoints?.first(where: { $0.id == id }) { MatingJointEditor(doc:doc,initial:joint) }
                                else { CutEditor(doc:doc,partID:part.id,cut:cut) }
                            }
                        case .operation:
                            if let op = part.operations?.first(where: { $0.id == reference.feature }) { OperationEditor(doc:doc,partID:part.id,operation:op) }
                        case .trim:
                            var copy = part
                            let _ = { copy.trims = part.trims.filter { $0.id == reference.feature } }()
                            TrimEditor(doc:doc,part:copy)
                        }
                        FeatureToolAssignment(doc:doc,reference:reference)
                    }.padding(8)
                }
            } else { Text("This part was removed.") }
            HStack { StatusMessage(doc:doc).font(.caption).foregroundStyle(.secondary).lineLimit(3); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width:760,height:740).background(Color(nsColor:.windowBackgroundColor))
        .onDisappear { doc.clearParameterPreview() }
    }
}
struct FeatureToolAssignment: View {
    @ObservedObject var doc: Document
    let reference: FeatureRef
    var body: some View {
        if let profile = doc.studio.setupProfile,let part = doc.part(reference.part) {
            GroupBox("Cutter for review") {
                Picker("Tool",selection:Binding(get: { part.toolAssignments?[reference.feature.uuidString] },set: { tool in
                    doc.edit(part.id) { p in if p.toolAssignments == nil { p.toolAssignments = [:] }; p.toolAssignments?[reference.feature.uuidString] = tool }
                })) {
                    Text("Setup default").tag(nil as UUID?)
                    ForEach(profile.tools) { Text($0.name + " · " + doc.fmt($0.diameter)).tag(Optional($0.id)) }
                }.padding(8)
            }
        } else { Text("Choose a CNC setup to assign a cutter and check diameter/reach.").font(.caption).foregroundStyle(.secondary) }
    }
}

struct PatternEditor: View {
    @ObservedObject var doc: Document
    let partID: UUID
    @State private var draft: DrillingPattern
    @State private var field = PatternField.columns
    @State private var expression = ""
    init(doc:Document,partID:UUID,initial:DrillingPattern) { self.doc = doc; self.partID = partID; _draft = State(initialValue:initial) }
    private var evaluated: Result<(DrillingPattern,[MachiningOperation]),Error> {
        Result {
            guard let part = doc.part(partID) else { throw ModelValidation.Failure(message:"The part was removed.") }
            var pattern = draft; try pattern.evaluate(Parametric.values(doc.studio.parameters ?? []))
            return (pattern,try pattern.generated(size:part.size))
        }
    }
    private func driven(_ field:PatternField)->Bool { (draft.expressions ?? []).contains { $0.field == field } }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            TextField("Pattern name",text:$draft.name).textFieldStyle(.roundedBorder)
            AxisPicker(title:"Face normal",value:$draft.axis)
            Toggle("Positive face",isOn:$draft.positive)
            Text("Face coordinates: U = \(FaceRef.axisNames[draft.u]), V = \(FaceRef.axisNames[draft.v]). Editing this definition updates every hole in the pattern.").font(.caption)
            HStack {
                Picker("Layout",selection:$draft.layout) { ForEach(PatternLayout.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Picker("Placement",selection:$draft.placement) { ForEach(PatternPlacement.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            }
            HStack {
                Stepper("Columns / holes: \(draft.columns)",value:$draft.columns,in:1...100).disabled(driven(.columns))
                if draft.layout == .grid { Stepper("Rows: \(draft.rows)",value:$draft.rows,in:1...100).disabled(driven(.rows)) }
            }
            if draft.placement == .fixed {
                HStack { DimField(label:"Start U",value:$draft.origin.x,metric:doc.metric); DimField(label:"Start V",value:$draft.origin.y,metric:doc.metric) }
            }
            if draft.placement == .margins || draft.spanU || draft.spanV {
                HStack {
                    DimField(label:"Margin U",value:$draft.margin.x,metric:doc.metric,minimum:0).disabled(driven(.marginU))
                    DimField(label:"Margin V",value:$draft.margin.y,metric:doc.metric,minimum:0).disabled(driven(.marginV))
                }
            }
            if draft.layout == .grid {
                HStack {
                    DimField(label:"Pitch U",value:$draft.pitch.x,metric:doc.metric,minimum:0).disabled(draft.spanU || driven(.pitchU))
                    DimField(label:"Pitch V",value:$draft.pitch.y,metric:doc.metric,minimum:0).disabled(draft.spanV || driven(.pitchV))
                }
                HStack { Toggle("Span U between margins",isOn:$draft.spanU); Toggle("Span V between margins",isOn:$draft.spanV) }
                HStack { Toggle("Measure U from far edge",isOn:$draft.farU); Toggle("Measure V from far edge",isOn:$draft.farV) }
            } else { DimField(label:"Radius",value:$draft.radius,metric:doc.metric,minimum:0.001).disabled(driven(.radius)) }
            HStack {
                DimField(label:"Hole diameter",value:$draft.diameter,metric:doc.metric,minimum:0.001).disabled(driven(.diameter))
                DimField(label:"Depth",value:$draft.depth,metric:doc.metric,minimum:0.001).disabled(draft.through || driven(.depth))
            }
            Toggle("Through stock (follows thickness)",isOn:$draft.through)
            Picker("Head recess",selection:$draft.recess) { ForEach(HeadRecess.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            if draft.recess != .none {
                HStack {
                    DimField(label:"Head diameter",value:$draft.recessDiameter,metric:doc.metric,minimum:0.001)
                    if draft.recess == .counterbore { DimField(label:"Head depth",value:$draft.recessDepth,metric:doc.metric,minimum:0.001) }
                    else { AngleField(label:"Included angle",value:$draft.includedAngle,limit:150) }
                }
            }
            if let part = doc.part(partID),case .success(let value) = evaluated {
                PatternFacePreview(size:part.size,pattern:value.0,operations:value.1).frame(height:170)
                Text("\(value.0.layout == .circular ? value.0.columns : value.0.columns * value.0.rows) holes · \(value.1.count) machining operations").font(.caption).foregroundStyle(.secondary)
            }
            if case .failure(let error) = evaluated { Text(error.localizedDescription).font(.callout).foregroundStyle(.red) }
            DisclosureGroup("Drive pattern dimensions with parameters") {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(draft.expressions ?? []) { binding in
                        HStack { Text(binding.field.rawValue + " = " + binding.expression); Spacer(); Button("Unlink") { draft.expressions?.removeAll { $0.field == binding.field } } }
                    }
                    Picker("Dimension",selection:$field) { ForEach(PatternField.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("e.g. pin_count or thickness / 2",text:$expression).textFieldStyle(.roundedBorder)
                    Button("Use expression") {
                        var bindings = draft.expressions ?? []; bindings.removeAll { $0.field == field }
                        bindings.append(PatternExpression(field:field,expression:expression,metricLiterals:doc.metric)); draft.expressions = bindings
                    }.disabled(expression.trimmingCharacters(in:.whitespaces).isEmpty)
                }.padding(8)
            }
            Toggle("Pattern enabled",isOn:Binding(get: { !draft.suppressed },set: { draft.suppressed = !$0 }))
            HStack {
                Button("Apply pattern & regenerate") {
                    doc.clearParameterPreview()
                    if doc.savePattern(draft,partID:partID) { doc.status = "Regenerated ‘\(draft.name)’ and its later features." }
                }.buttonStyle(.borderedProminent).disabled((try? evaluated.get()) == nil)
                Button("Convert to individual holes") { doc.explodePattern(FeatureRef(part:partID,kind:.pattern,feature:draft.id)) }
                    .disabled(doc.part(partID)?.patterns?.contains(where: { $0.id == draft.id }) != true)
                    .help("Detaches the pattern definition so each hole can be edited separately. Undo restores the pattern.")
            }
        }
    }
}
struct PatternFacePreview: View {
    let size: SIMD3<Double>
    let pattern: DrillingPattern
    let operations: [MachiningOperation]
    var body: some View {
        Canvas { context,canvas in
            let scale = min((canvas.width-20)/size[pattern.u],(canvas.height-20)/size[pattern.v])
            let origin = CGPoint(x:(canvas.width-size[pattern.u]*scale)/2,y:(canvas.height-size[pattern.v]*scale)/2)
            let rect = CGRect(x:origin.x,y:origin.y,width:size[pattern.u]*scale,height:size[pattern.v]*scale)
            context.fill(Path(rect),with:.color(.brown.opacity(0.1))); context.stroke(Path(rect),with:.color(.secondary),lineWidth:1)
            for op in operations {
                var path = Path(); path.addLines(op.contour.map { CGPoint(x:origin.x+$0.x*scale,y:origin.y+(size[pattern.v]-$0.y)*scale) }); path.closeSubpath()
                context.stroke(path,with:.color(op.kind == "Drill" ? .blue : .purple),lineWidth:1.5)
            }
        }.background(.background,in:RoundedRectangle(cornerRadius:6))
    }
}

struct FeatureTimelinePanel: View {
    @ObservedObject var doc: Document
    let part: Part
    @State private var editing: FeatureRef?
    var body: some View {
        GroupBox("Feature history — source → finished part") {
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text("0 · Source blank / profile").font(.headline)
                    Spacer()
                    Button("Preview blank") { doc.clearParameterPreview(); doc.historyInspection = HistoryInspection(part:part.id,through:0) }
                }
                DisclosureGroup("Edit source and replay later features") {
                    VStack {
                        ProfileSection(doc:doc,part:part)
                        ForEach(0..<3) { axis in
                            DimField(label:FaceRef.axisNames[axis],value:Binding(get: { doc.part(part.id)?.size[axis] ?? 0 },set: { value in doc.edit(part.id) { $0.size[axis] = value } }),metric:doc.metric,minimum:1/32)
                        }
                    }
                }
                ForEach(Array(part.featureSteps.enumerated()),id:\.element.id) { index,step in
                    let ref = FeatureRef(part:part.id,kind:step.kind,feature:step.feature)
                    HStack {
                        Toggle("",isOn:Binding(get: { enabled(step) },set: { v in doc.toggleFeature(ref,enabled:v) })).labelsHidden()
                        Text("\(index+1) · \(part.featureName(step))").lineLimit(2)
                        Spacer()
                        Button("Edit") { doc.selectFeature(ref); editing = ref }
                        Button("◀") { doc.reorderFeature(ref,delta:-1) }.help("Move earlier")
                        Button("▶") { doc.reorderFeature(ref,delta:1) }.help("Move later")
                        Button("Preview to here") { doc.clearParameterPreview(); doc.historyInspection = HistoryInspection(part:part.id,through:index+1) }
                    }.padding(4).background(doc.historyInspection?.part == part.id && doc.historyInspection?.through == index+1 ? Color.accentColor.opacity(0.1) : .clear,in:RoundedRectangle(cornerRadius:4))
                }
                if doc.historyInspection != nil {
                    HStack { Text("Inspecting an earlier stage. Edits regenerate the full feature sequence.").font(.caption); Spacer(); Button("Resume full history") { doc.resumeFeatureHistory() } }
                }
                Button("Regenerate full part") {
                    doc.resumeFeatureHistory()
                    if doc.transaction({}) { doc.status = "Regenerated the source and every later feature of ‘\(part.name)’." }
                }
            }.padding(8)
        }
        .sheet(item:$editing) { FeatureEditorSheet(doc:doc,reference:$0) }
    }
    private func enabled(_ step: FeatureStep) -> Bool {
        switch step.kind {
        case .cut: return part.cuts.first { $0.id == step.feature }?.suppressed != true
        case .operation: return part.operations?.first { $0.id == step.feature }?.suppressed != true
        case .pattern: return part.patterns?.first { $0.id == step.feature }?.suppressed != true
        case .trim: return part.trims.first { $0.id == step.feature }?.suppressed != true
        }
    }
}
extension Document {
    func toggleFeature(_ ref: FeatureRef,enabled: Bool) {
        if let cut = part(ref.part)?.cuts.first(where: { $0.id == ref.feature }),let id = cut.mateID {
            transaction { if let i = studio.matingJoints?.firstIndex(where: { $0.id == id }) { studio.matingJoints![i].suppressed = !enabled } }; return
        }
        edit(ref.part) { p in
            switch ref.kind {
            case .cut: if let i = p.cuts.firstIndex(where: { $0.id == ref.feature }) { p.cuts[i].suppressed = !enabled }
            case .operation: if let i = p.operations?.firstIndex(where: { $0.id == ref.feature }) { p.operations![i].suppressed = !enabled }
            case .pattern: if let i = p.patterns?.firstIndex(where: { $0.id == ref.feature }) { p.patterns![i].suppressed = !enabled }
            case .trim: if let i = p.trims.firstIndex(where: { $0.id == ref.feature }) { p.trims[i].suppressed = !enabled }
            }
            p.featureOrder = p.featureSteps
        }
    }
}
