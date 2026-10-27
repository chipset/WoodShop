import SwiftUI

struct SetupProfilesPanel: View {
    @ObservedObject var doc: Document
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CNCSetupProfile()
    private var error: String? { do { try draft.validate(); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Reusable CNC setups").font(.title2.bold())
            if let message = doc.setupProfileStore.loadError { Text(message).font(.caption).foregroundStyle(.orange) }
            Text("Saved locally for future projects; the setup in use is also embedded in your project and VCarve package.").font(.caption).foregroundStyle(.secondary)
            HStack(alignment:.top,spacing:16) {
                VStack(alignment:.leading,spacing:8) {
                    List(doc.setupProfiles) { profile in Button(profile.name) { draft = profile }.buttonStyle(.plain) }
                    Button("New setup") { draft = CNCSetupProfile() }
                    Button("Duplicate setup") { draft.id = UUID(); draft.name += " copy" }
                    Button("Delete saved setup",role:.destructive) { doc.deleteSetup(draft.id) }
                }.frame(width:190)
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        TextField("Setup name",text:$draft.name).textFieldStyle(.roundedBorder)
                        Picker("Material",selection:$draft.species) { ForEach(Species.allCases) { Text($0.rawValue).tag($0) } }
                        HStack { DimField(label:"Sheet length",value:$draft.sheetLength,metric:draft.metric,minimum:1/32); DimField(label:"Sheet width",value:$draft.sheetWidth,metric:draft.metric,minimum:1/32) }
                        DimField(label:"Actual thickness",value:$draft.measuredThickness,metric:draft.metric,minimum:1/32)
                        Text("Measure your stock; nominal plywood thickness can differ from the material on your machine.").font(.caption).foregroundStyle(.secondary)
                        HStack { DimField(label:"Part spacing",value:$draft.gap,metric:draft.metric,minimum:0); DimField(label:"Fit clearance",value:$draft.clearance,metric:draft.metric,minimum:0) }
                        Toggle("Export in millimeters",isOn:$draft.metric)
                        Toggle("Registration pins",isOn:$draft.registration.enabled)
                        if draft.registration.enabled {
                            HStack { DimField(label:"Pin diameter",value:$draft.registration.diameter,metric:draft.metric,minimum:0.001); DimField(label:"Pin inset",value:$draft.registration.inset,metric:draft.metric,minimum:0.001) }
                        }
                        Divider()
                        Text("Cutters for feature checks").font(.headline)
                        ForEach($draft.tools) { $tool in
                            GroupBox {
                                VStack(alignment:.leading,spacing:6) {
                                    TextField("Tool name",text:$tool.name)
                                    Picker("Type",selection:$tool.kind) { ForEach(CuttingToolKind.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                                    HStack { DimField(label:"Diameter",value:$tool.diameter,metric:draft.metric,minimum:0.001); DimField(label:"Flute length",value:$tool.fluteLength,metric:draft.metric,minimum:0.001) }
                                    Button("Remove cutter") { let id = tool.id; draft.tools.removeAll { $0.id == id }; if draft.activeTool == id { draft.activeTool = nil } }
                                }.padding(6)
                            }
                        }
                        Button("Add cutter") { draft.tools.append(CuttingTool(name:"New cutter")) }
                        Picker("Default cutter",selection:$draft.activeTool) {
                            Text("First cutter").tag(nil as UUID?)
                            ForEach(draft.tools) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField("VCarve toolpath-template name (optional)",text:$draft.vcarveTemplate).textFieldStyle(.roundedBorder)
                        TextField("Setup notes",text:$draft.notes,axis:.vertical).textFieldStyle(.roundedBorder)
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    }.padding(8)
                }
            }
            HStack {
                StatusMessage(doc:doc).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Save for future projects") { _ = doc.saveSetup(draft) }.disabled(error != nil)
                Button("Use this setup") { if doc.activateSetup(draft) { doc.status = "Using ‘\(draft.name)’.";dismiss() } }.disabled(error != nil).buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width:1000,height:790).background(Color(nsColor:.windowBackgroundColor))
        .onAppear { draft = doc.studio.setupProfile ?? doc.setupProfiles.first ?? CNCSetupProfile() }
    }
}
struct MachiningReviewPanel: View {
    @ObservedObject var doc: Document
    var forCNCJob = false
    @State private var editing: FeatureRef?
    var body: some View {
        let issues = CNCAnalysis.review(forCNCJob ? doc.cncProject : doc.project)
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("Machining review").font(.headline)
                Spacer()
                Toggle("Highlight in model",isOn:$doc.showReviewHighlights)
            }
            Text("\(issues.filter { $0.severity == .error }.count) errors · \(issues.filter { $0.severity == .warning }.count) warnings. Errors block CNC export; inspect warnings before choosing a CAM strategy.").font(.caption).foregroundStyle(.secondary)
            List(issues) { issue in
                HStack(alignment:.top) {
                    Image(systemName:issue.severity == .error ? "xmark.octagon.fill" : (issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                        .foregroundStyle(issue.severity == .error ? Color.red : (issue.severity == .warning ? .orange : .secondary))
                    Button {
                        if let ref = issue.feature { doc.selectFeature(ref) } else { doc.select(issue.part) }
                        doc.showReviewHighlights = true
                    } label: { Text(issue.message).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain)
                    if let ref = issue.feature { Button("Edit feature") { doc.selectFeature(ref); editing = ref } }
                }.padding(.vertical,4)
            }
            if issues.isEmpty { Text("No geometry or cutter issues detected by the current checks. Continue with toolpath simulation in VCarve.").foregroundStyle(.secondary) }
        }.padding(12).sheet(item:$editing) { FeatureEditorSheet(doc:doc,reference:$0) }
    }
}
struct AssemblyStepsEditor: View {
    @ObservedObject var doc: Document
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Part labels & assembly sequence").font(.headline)
            HStack {
                Button("Generate suggested steps") { doc.transaction { doc.studio.assemblySteps = ShopIdentity.suggestedSteps(doc.project) } }
                Button("Add step") { doc.transaction { doc.studio.assemblySteps = (doc.studio.assemblySteps ?? []) + [AssemblyStep(text:"New assembly step",parts:Array(doc.selectedIDs))] } }
                Spacer()
                Button("Part labels PDF…") { doc.exportShopLabels() }
                Button("Assembly guide PDF…") { doc.exportAssemblyGuide() }
            }
            Text("Part identifiers match the model, CSV, drawings, labels, and VCarve files. Suggested steps are editable; arrange them for your chosen fastening method.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    ForEach(Array((doc.studio.assemblySteps ?? []).enumerated()),id:\.element.id) { index,step in
                        GroupBox("Step \(index+1)") {
                            VStack(alignment:.leading,spacing:6) {
                                TextField("Assembly instruction",text:Binding(get: { (doc.studio.assemblySteps ?? []).first { $0.id == step.id }?.text ?? "" },set: { text in doc.transaction { if let i = doc.studio.assemblySteps?.firstIndex(where: { $0.id == step.id }) { doc.studio.assemblySteps![i].text = text } } }),axis:.vertical)
                                Text(step.parts.compactMap { doc.part($0) }.map { ShopIdentity.label($0) + " " + $0.name }.joined(separator:", ")).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Use selected part references") { doc.transaction { if let i = doc.studio.assemblySteps?.firstIndex(where: { $0.id == step.id }) { doc.studio.assemblySteps![i].parts = Array(doc.selectedIDs) } } }
                                    Button("Earlier") { move(step.id,delta:-1) }
                                    Button("Later") { move(step.id,delta:1) }
                                    Button("Remove",role:.destructive) { doc.transaction { doc.studio.assemblySteps?.removeAll { $0.id == step.id } } }
                                }
                            }.padding(6)
                        }
                    }
                }
            }
        }.padding(12)
    }
    private func move(_ id:UUID,delta:Int) { doc.transaction { if let i = doc.studio.assemblySteps?.firstIndex(where: { $0.id == id }),doc.studio.assemblySteps!.indices.contains(i+delta) { doc.studio.assemblySteps!.swapAt(i,i+delta) } } }
}
