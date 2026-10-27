import SwiftUI

struct DesignPanel: View {
    @ObservedObject var doc: Document
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parameters & Design History").font(.title2.bold())
            TabView {
                ParametersEditor(doc: doc).tabItem { Text("Named Parameters") }
                FeatureHistoryEditor(doc: doc).tabItem { Text("Part Features & Expressions") }
                HistoryTimeline(doc: doc).tabItem { Text("Design History") }
            }
            HStack { Text(doc.status).font(.callout).foregroundStyle(.secondary).lineLimit(3); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 940, height: 740).background(Color(nsColor: .windowBackgroundColor))
    }
}
struct ParametersEditor: View {
    @ObservedObject var doc: Document
    @State private var draft: [DesignParameter] = []
    @State private var preview: ParameterPreview?
    @State private var livePreview = true
    @State private var previewTask: Task<Void,Never>?
    private var evaluated: Result<[String: Quantity], Error> { Result { try Parametric.values(draft) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name important dimensions once, then use them in parts and joints. For example: cabinet_width = 600mm, thickness = 18mm, shelf_length = cabinet_width - 2 * thickness.").font(.callout)
            Text("Supports + − × /, parentheses, min(), max(), abs(), mm/cm/in, and deg. Bare length literals use the units chosen when the parameter is created.").font(.caption).foregroundStyle(.secondary)
            HStack { Text("Name").frame(width: 180, alignment: .leading); Text("Expression").frame(maxWidth: .infinity, alignment: .leading); Text("Type").frame(width: 100); Text("Value").frame(width: 130) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($draft) { $parameter in
                        HStack {
                            TextField("name", text: $parameter.name).frame(width: 180)
                            TextField("expression", text: $parameter.expression)
                            Picker("", selection: $parameter.kind) { ForEach(ParameterKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 100)
                            Text(value(parameter)).monospacedDigit().frame(width: 130)
                            Button { draft.removeAll { $0.id == parameter.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }.textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack { Toggle("Live model preview",isOn:$livePreview); Spacer(); if let preview { Text("\(preview.affected.count) parts affected").foregroundStyle(.secondary) }; Button("Discard preview") { previewTask?.cancel(); doc.clearParameterPreview(); preview = nil } }
            if let preview {
                if preview.conflicts.isEmpty && !preview.affected.isEmpty {
                    Text(preview.affected.compactMap { doc.part($0) }.map { ShopIdentity.label($0) + " " + $0.name }.joined(separator:", ")).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                if !preview.conflicts.isEmpty {
                    ScrollView { VStack(alignment:.leading,spacing:6) { ForEach(preview.conflicts) { conflict in
                        HStack(alignment:.top) {
                            Text(conflict.message).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading)
                            if let feature = conflict.feature {
                                Button("Edit feature") {
                                    previewTask?.cancel();doc.clearParameterPreview();self.preview = nil
                                    doc.select(feature.part);doc.selectedFeature = feature;doc.showDesign = false
                                    DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { doc.showFeatureEditor = true }
                                }
                            } else if let id = conflict.part { Button("Select part") { doc.select(id) } }
                        }
                    } } }.frame(maxHeight:130)
                }
            }
            if case .failure(let error) = evaluated { Text(error.localizedDescription).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Add parameter") { draft.append(DesignParameter(name: "dimension_\(draft.count + 1)", expression: doc.metric ? "100mm" : "4in", metricLiterals: doc.metric)) }
                Button("Add cabinet parameters") { draft = ProjectTemplates.mergedParameters(draft) }
                Button("Create parametric bookcase") { doc.insertParametricBookcase(); draft = doc.studio.parameters ?? [] }
                Spacer()
                Button("Reset draft") { draft = doc.studio.parameters ?? [] }
                Button("Apply to entire design") {
                    previewTask?.cancel(); doc.clearParameterPreview(); preview = nil
                    if doc.setParameters(draft) { doc.status = "Updated parameters and all dependent part and joint dimensions." }
                }.disabled((try? evaluated.get()) == nil || preview?.canApply == false)
            }
        }.padding(12).onAppear { draft = doc.studio.parameters ?? [] }
        .onChange(of:draft) { _,_ in schedulePreview() }
        .onChange(of:livePreview) { _,enabled in if enabled { schedulePreview() } else { previewTask?.cancel(); doc.clearParameterPreview(); preview = nil } }
        .onDisappear { previewTask?.cancel(); doc.clearParameterPreview() }
    }
    private func schedulePreview() {
        previewTask?.cancel()
        guard livePreview else { return }
        let values = draft
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds:250_000_000)
            guard !Task.isCancelled else { return }
            preview = doc.useParameterPreview(values)
        }
    }
    private func value(_ p: DesignParameter) -> String {
        guard case .success(let values) = evaluated, let q = values[p.name.lowercased()] else { return "—" }
        return q.dimension == 1 ? doc.fmt(q.value) : Units.decimal(q.value) + (q.dimension == 2 ? "°" : "")
    }
}
struct FeatureHistoryEditor: View {
    @ObservedObject var doc: Document
    @State private var target = BindingTarget.size
    @State private var axis = 0
    @State private var feature: UUID?
    @State private var expression = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let part = doc.selectedPart {
                    Text(part.name).font(.headline)
                    FeatureTimelinePanel(doc:doc,part:part)
                    Divider()
                    Text("Dimension expressions").font(.headline)
                    ForEach(part.bindings ?? []) { binding in
                        HStack {
                            Text("\(binding.target.rawValue)\([.size,.position,.rotation].contains(binding.target) ? " " + FaceRef.axisNames[binding.axis] : ""): \(binding.expression)")
                            Spacer()
                            Button("Unlink") { doc.edit(part.id) { $0.bindings?.removeAll { $0.id == binding.id } } }
                        }
                    }
                    Picker("Drive", selection: $target) { ForEach(BindingTarget.allCases) { Text($0.rawValue).tag($0) } }
                    if [.size,.position,.rotation].contains(target) { AxisPicker(title: "Axis", value: $axis) }
                    else {
                        Picker("Feature", selection: $feature) {
                            Text("Choose feature").tag(nil as UUID?)
                            if [.cutWidth,.cutDepth,.cutOffset,.clearance].contains(target) {
                                ForEach(part.cuts) { Text($0.kind + " " + $0.id.uuidString.prefix(4)).tag(Optional($0.id)) }
                            } else { ForEach(part.operations ?? []) { Text($0.name).tag(Optional($0.id)) } }
                        }
                    }
                    TextField("e.g. cabinet_width - 2 * thickness", text: $expression).textFieldStyle(.roundedBorder)
                    Button("Bind expression") {
                        doc.bind(DesignBinding(target: target, axis: axis, feature: [.size,.position,.rotation].contains(target) ? nil : feature, expression: expression, metricLiterals: doc.metric), to: part.id)
                    }.disabled(expression.trimmingCharacters(in: .whitespaces).isEmpty || ![.size,.position,.rotation].contains(target) && feature == nil)
                } else { Text("Select a part first.").foregroundStyle(.secondary) }
            }.padding(12)
        }
    }
    private func moveCut(_ id: UUID, delta: Int, part: Part) {
        doc.reorderFeature(FeatureRef(part:part.id,kind:.cut,feature:id),delta:delta)
    }
}
struct OperationEditor: View {
    @ObservedObject var doc: Document
    let partID: UUID
    let operation: MachiningOperation
    @State private var draft: MachiningOperation?
    @State private var editingSketch = false
    private var current: MachiningOperation { draft ?? operation }
    var body: some View {
        if operation.sketch != nil {
            Button("Edit face sketch, curves & cutting mode…") { editingSketch = true }
                .sheet(isPresented:$editingSketch) { FaceSketchEditor(doc:doc,partID:partID,initial:operation) }
        } else { legacyEditor }
    }
    private var legacyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: Binding(get: { current.name }, set: { v in var op = current; op.name = v; draft = op }))
            DimField(label: "Depth", value: Binding(get: { current.depth }, set: { v in var op = current; op.depth = v; draft = op }), metric: doc.metric, minimum: 0.001)
            Text("Face \(current.positive ? "+" : "−")\(FaceRef.axisNames[current.axis]) · opening coordinates from the minimum corner").font(.caption).foregroundStyle(.secondary)
            HStack {
                openingField("Center U",axis:0,center:true)
                openingField("Center V",axis:1,center:true)
            }
            HStack {
                openingField(current.kind == "Drill" ? "Diameter" : "Opening U",axis:0,center:false)
                if current.kind != "Drill" { openingField("Opening V",axis:1,center:false) }
            }
            if let part = doc.part(partID),let error = current.validation(size:part.size,checkStock:current.suppressed != true) { Text(error).font(.caption).foregroundStyle(.red) }
            Toggle("Feature enabled", isOn: Binding(get: { current.suppressed != true }, set: { v in var op = current; op.suppressed = !v; draft = op }))
            HStack {
                Button("Apply feature changes") { if doc.saveOperation(current,partID:partID) { draft = nil } }
                    .disabled(doc.part(partID).map { current.validation(size:$0.size,checkStock:current.suppressed != true) != nil } ?? true)
                Button("Delete feature", role: .destructive) { doc.edit(partID) { p in p.operations?.removeAll { $0.id == operation.id }; p.bindings?.removeAll { $0.feature == operation.id } } }
            }
        }.padding(8).onChange(of: operation) { _, _ in draft = nil }
    }
    private func openingField(_ label: String,axis: Int,center: Bool) -> some View {
        DimField(label:label,value:Binding(get: { center ? current.openingBounds.center[axis] : current.openingBounds.span[axis] },set: { value in
            var bounds = current.openingBounds
            if center { bounds.center[axis] = value } else {
                bounds.span[axis] = value
                if current.kind == "Drill" { bounds.span[1-axis] = value }
            }
            if let changed = try? current.repositioned(center:bounds.center,span:bounds.span) { draft = changed }
        }),metric:doc.metric,minimum:center ? -100000 : 0.001)
    }
}
struct HistoryTimeline: View {
    @ObservedObject var doc: Document
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved design revisions").font(.headline)
            Text("History travels with the project. Restore a revision to recover its parts, joint settings, links, and parameters; Undo can reverse the restore. The most recent 80 revisions are retained.").font(.callout).foregroundStyle(.secondary)
            List((doc.studio.history ?? []).reversed()) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.name).font(.headline)
                        Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.snapshot.parts.count) parts · \(entry.snapshot.parameters.count) parameters").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore this revision") { doc.restoreHistory(entry) }
                }.padding(.vertical, 4)
            }
        }.padding(12)
    }
}
