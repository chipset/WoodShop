import SwiftUI

struct VectorFields: View {
    let title: String
    @Binding var value: SIMD3<Double>
    var metric: Bool
    var body: some View {
        GroupBox(title) {
            HStack {
                ForEach(0..<3) { axis in
                    DimField(label: FaceRef.axisNames[axis], value: Binding(get: { value[axis] }, set: { value[axis] = $0 }), metric: metric)
                }
            }.padding(5)
        }
    }
}
struct AxisPicker: View {
    let title: String
    @Binding var value: Int
    var body: some View { Picker(title, selection: $value) { ForEach(0..<3) { Text(FaceRef.axisNames[$0]).tag($0) } }.pickerStyle(.segmented) }
}
struct WorkshopView: View {
    @ObservedObject var doc: Document
    let ctrl: SceneController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workshop").font(.title2.bold())
            Text(doc.selectedPart.map { "Active part: " + $0.name } ?? "Select a part in the model to use machining and face tools.").foregroundStyle(.secondary)
            TabView(selection: $doc.workshopTab) {
                MachiningWorkbench(doc: doc).tabItem { Text("CNC & Joinery") }.tag(0)
                AssemblyWorkbench(doc: doc).tabItem { Text("Assemblies & Transforms") }.tag(1)
                DrawingWorkbench(doc: doc).tabItem { Text("Sketch & Sweep") }.tag(2)
                DocumentationWorkbench(doc: doc, ctrl: ctrl).tabItem { Text("Guides, Views & Dimensions") }.tag(3)
                LibraryWorkbench(doc: doc).tabItem { Text("Import & Library") }.tag(4)
            }
            HStack {
                Text(doc.status).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 1000, height: 800).background(Color(nsColor: .windowBackgroundColor))
    }
}
struct ReliefEditor: View {
    @ObservedObject var doc: Document
    let partID: UUID
    let cut: Cut
    @State private var relief = CornerRelief(style: .none)
    @State private var allowance = 0.0
    var body: some View {
        DisclosureGroup("CNC relief & fit") {
            VStack(alignment: .leading, spacing: 7) {
                Picker("Relief", selection: $relief.style) { ForEach(ReliefStyle.allCases) { Text($0.rawValue).tag($0) } }
                DimField(label: "Cutter diameter", value: $relief.diameter, metric: doc.metric, minimum: 0.001)
                HStack {
                    ForEach(0..<4) { i in Toggle("\(i + 1)", isOn: Binding(get: { relief.corners[i] }, set: { relief.corners[i] = $0 })) }
                }
                Text("Corners 1–4 run counterclockwise from minimum U/V on the selected face.").font(.caption).foregroundStyle(.secondary)
                DimField(label: "Fit clearance", value: $allowance, metric: doc.metric, minimum: 0)
                Text("Clearance increases the pocket's total width and length. Relief radius is half the cutter diameter.").font(.caption).foregroundStyle(.secondary)
                Button("Apply relief & fit") {
                    doc.edit(partID) { p in
                        if let i = p.cuts.firstIndex(where: { $0.id == cut.id }) {
                            p.cuts[i].relief = relief.style == .none ? nil : relief
                            p.cuts[i].allowance = allowance == 0 ? nil : allowance
                        }
                    }
                }
            }.padding(.vertical, 6)
        }
        .onAppear { relief = cut.relief ?? CornerRelief(style: .none); allowance = cut.allowance ?? 0 }
    }
}
struct MachiningWorkbench: View {
    @ObservedObject var doc: Document
    @State private var axis = 1
    @State private var positive = true
    @State private var diameter = 0.25
    @State private var depth = 0.5
    @State private var start = SIMD2<Double>(1, 1)
    @State private var spacing = SIMD2<Double>(2, 2)
    @State private var rows = 1
    @State private var columns = 1
    @State private var circular = false
    @State private var radius = 2.0
    @State private var counter = "None"
    @State private var counterDiameter = 0.5
    @State private var counterDepth = 0.125
    @State private var angle = 82.0
    @State private var fingers = 4
    @State private var clearance = 0.005
    @State private var dovetail = false
    @State private var dovetailAngle = 8.0
    @State private var editingFeature: FeatureRef?
    @State private var mating = false
    @State private var newPattern: DrillingPattern?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("Fit a shelf into receiving boards…") { mating = true }.buttonStyle(.borderedProminent)
                    Button("New editable drilling pattern…") {
                        guard let part = doc.selectedPart else { return }
                        var pattern = DrillingPattern(); pattern.axis = axis; pattern.positive = positive
                        pattern.depth = min(pattern.depth,part.size[axis]); pattern.margin = SIMD2(min(1,part.size[pattern.u]/2),min(1,part.size[pattern.v]/2))
                        newPattern = pattern
                    }.disabled(doc.selectedPart == nil)
                }
                AxisPicker(title: "Face normal", value: $axis)
                Toggle("Positive face", isOn: $positive)
                Text("Coordinates U = \(FaceRef.axisNames[(axis + 1) % 3]), V = \(FaceRef.axisNames[(axis + 2) % 3]), measured from the part's minimum corner.").font(.caption)
                GroupBox("Drilling patterns") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            DimField(label: "Diameter", value: $diameter, metric: doc.metric, minimum: 0.001)
                            DimField(label: "Depth", value: $depth, metric: doc.metric, minimum: 0.001)
                            Button("Through") { if let p = doc.selectedPart { depth = p.size[axis] } }
                        }
                        HStack {
                            DimField(label: "Start U", value: $start.x, metric: doc.metric)
                            DimField(label: "Start V", value: $start.y, metric: doc.metric)
                        }
                        Toggle("Circular bolt pattern", isOn: $circular)
                        HStack {
                            Stepper("Columns / holes: \(columns)", value: $columns, in: 1...50)
                            if circular { DimField(label: "Radius", value: $radius, metric: doc.metric, minimum: 0.001) }
                            else { Stepper("Rows: \(rows)", value: $rows, in: 1...50) }
                        }
                        if !circular {
                            HStack {
                                DimField(label: "Pitch U", value: $spacing.x, metric: doc.metric, minimum: 0)
                                DimField(label: "Pitch V", value: $spacing.y, metric: doc.metric, minimum: 0)
                            }
                        }
                        Picker("Head recess", selection: $counter) { ForEach(["None", "Counterbore", "Countersink"], id: \.self) { Text($0) } }
                        if counter != "None" {
                            HStack {
                                DimField(label: "Head diameter", value: $counterDiameter, metric: doc.metric, minimum: 0.001)
                                if counter == "Counterbore" { DimField(label: "Recess depth", value: $counterDepth, metric: doc.metric, minimum: 0.001) }
                                else { AngleField(label: "Included angle", value: $angle, limit: 150) }
                            }
                        }
                        Button("Add drilling pattern") { addHoles() }.disabled(doc.selectedPart == nil)
                    }.padding(8)
                }
                GroupBox("Finger joints & dovetails") {
                    VStack(alignment: .leading, spacing: 10) {
                        Stepper("Fingers: \(fingers)", value: $fingers, in: 1...24)
                        HStack {
                            DimField(label: "Joint depth", value: $depth, metric: doc.metric, minimum: 0.001)
                            DimField(label: "Fit clearance", value: $clearance, metric: doc.metric, minimum: 0)
                        }
                        Toggle("Dovetail taper", isOn: $dovetail)
                        if dovetail { AngleField(label: "Taper angle", value: $dovetailAngle, limit: 20) }
                        Text("Patterns run across U. Select two equal-width boards to create complementary sockets on opposing faces. Position the boards in the assembly before machining.").font(.caption).foregroundStyle(.secondary)
                        Button("Create joint on selected board(s)") { addJoint() }.disabled(doc.selectedIDs.isEmpty || doc.selectedIDs.count > 2)
                    }.padding(8)
                }
                if let part = doc.selectedPart {
                    GroupBox("Editable patterns") {
                        VStack(alignment:.leading) {
                            ForEach(part.patterns ?? []) { pattern in
                                HStack { Text(pattern.name + " · \(pattern.layout == .circular ? pattern.columns : pattern.columns * pattern.rows) holes"); Spacer(); Button("Edit pattern") { editingFeature = FeatureRef(part:part.id,kind:.pattern,feature:pattern.id) } }
                            }
                        }.padding(6)
                    }
                    GroupBox("Machining operations") {
                        VStack(alignment: .leading) {
                            ForEach(part.operations ?? []) { op in
                                HStack {
                                    Text("\(op.name) · \(doc.fmt(op.depth)) deep · \(op.positive ? "+" : "−")\(FaceRef.axisNames[op.axis])")
                                    Spacer()
                                    Button("Edit / parameterize") { doc.showWorkshop = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { doc.showDesign = true } }
                                    Button("Remove") { doc.edit(part.id) { $0.operations?.removeAll { $0.id == op.id } } }
                                }
                            }
                        }.padding(6)
                    }
                    ForEach(part.cuts.filter { !$0.additive }) { cut in ReliefEditor(doc: doc, partID: part.id, cut: cut) }
                }
                GroupBox("Nesting & two-sided registration") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let p = doc.selectedPart {
                            Toggle("Use positive thickness face as CNC top", isOn: Binding(get: { p.cncTopPositive ?? true }, set: { v in doc.edit(p.id) { $0.cncTopPositive = v } }))
                            Toggle("Allow selected part to rotate 90° on the sheet", isOn: Binding(get: { p.allowNestingRotation ?? false }, set: { v in doc.edit(p.id) { $0.allowNestingRotation = v } }))
                        }
                        Text("Leave rotation off to preserve the specified grain direction.").font(.caption)
                        Toggle("Add registration drilling", isOn: Binding(get: { doc.studio.registration.enabled }, set: { v in doc.transaction { doc.studio.registration.enabled = v } }))
                        DimField(label: "Pin diameter", value: Binding(get: { doc.studio.registration.diameter }, set: { v in doc.transaction { doc.studio.registration.diameter = v } }), metric: doc.metric, minimum: 0.001)
                        DimField(label: "Pin inset", value: Binding(get: { doc.studio.registration.inset }, set: { v in doc.transaction { doc.studio.registration.inset = v } }), metric: doc.metric, minimum: 0.001)
                        Text("Reserve a clear strip at the pin locations. Bottom export flips the sheet about its length axis; use the same stock origin and the marked registration holes.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }.padding(12)
        }
        .onAppear {
            if let part = doc.selectedPart {
                if let face = doc.selectedFace,face.part == part.id { axis = face.axis;positive = face.positive }
                else { axis = part.materialAxes.t;positive = part.cncTopPositive ?? true }
                depth = min(depth,part.size[axis])
                diameter = doc.studio.setupProfile?.defaultTool?.diameter ?? diameter
            }
        }
        .sheet(item:$editingFeature) { FeatureEditorSheet(doc:doc,reference:$0) }
        .sheet(item:$newPattern) { pattern in
            VStack {
                ScrollView { if let part = doc.selectedPart { PatternEditor(doc:doc,partID:part.id,initial:pattern) } }
                Button("Done") { newPattern = nil }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(width:760,height:740)
        }
        .sheet(isPresented:$mating) { MatingJointWizard(doc:doc) }
        .onAppear { axis = doc.selectedFace?.axis ?? doc.selectedPart?.materialAxes.t ?? 1; positive = doc.selectedFace?.positive ?? doc.selectedPart?.cncTopPositive ?? true }
    }
    private func addHoles() {
        guard let part = doc.selectedPart else { return }
        var pattern = DrillingPattern()
        pattern.name = circular ? "Circular drilling pattern" : "Grid drilling pattern"
        pattern.axis = axis; pattern.positive = positive; pattern.layout = circular ? .circular : .grid
        pattern.placement = .fixed; pattern.origin = start; pattern.pitch = spacing; pattern.columns = columns; pattern.rows = rows
        pattern.diameter = diameter; pattern.depth = depth; pattern.through = abs(depth-part.size[axis]) < 1e-8; pattern.radius = radius
        pattern.recess = counter == "Countersink" ? .countersink : (counter == "Counterbore" ? .counterbore : .none)
        pattern.recessDiameter = counterDiameter; pattern.recessDepth = counterDepth; pattern.includedAngle = angle
        if doc.savePattern(pattern,partID:part.id) { doc.status = "Saved an editable drilling pattern. Click any hole to edit all its holes." }
    }
    private func addJoint() {
        let selected = doc.parts.filter { doc.selectedIDs.contains($0.id) }
        doc.transaction {
            if selected.count == 2, abs(selected[0].size[(axis + 1) % 3] - selected[1].size[(axis + 1) % 3]) > 1e-6 {
                throw ModelValidation.Failure(message: "Complementary boards must have equal widths along U.")
            }
            for (i, part) in selected.enumerated() {
                let ops = try JoineryTools.fingers(part: part, axis: axis, positive: i == 0 ? positive : !positive, count: fingers,
                    depth: depth, clearance: clearance, complementary: i == 1, dovetailAngle: dovetail ? dovetailAngle : 0)
                if let j = doc.parts.firstIndex(where: { $0.id == part.id }) { doc.parts[j].operations = (part.operations ?? []) + ops }
            }
        }
    }
}

struct CNCQuickActions: View {
    @ObservedObject var doc: Document
    let part: Part
    var body: some View {
        GroupBox("Machining") {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    metric("Joints",count:part.cuts.filter { $0.suppressed != true }.count)
                    metric("Operations",count:part.machiningOperations.filter { $0.suppressed != true }.count)
                    metric("Expressions",count:(part.bindings ?? []).count+(part.operations ?? []).reduce(0) { $0+($1.sketch?.expressions.count ?? 0) }+(part.patterns ?? []).reduce(0) { $0+($1.expressions?.count ?? 0) })
                }
                Divider()
                Button { doc.showMachiningRecipes = true } label: { Label("Add holes & joinery…",systemImage:"plus").frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.borderedProminent).disabled(doc.workspaceInspectionOnly)
                Button("Sketch a curve or pocket on this face…") { doc.beginFaceSketch() }.disabled(doc.workspaceInspectionOnly || part.mesh != nil)
                Button("Inspect feature history") { doc.inspectorPage = .history }
                Button("CNC layout & export…") { doc.beginCNCJob() }.disabled(doc.workspaceInspectionOnly)
                if doc.historyInspection != nil { Button("Resume finished part") { doc.resumeFeatureHistory() } }
            }.padding(7)
        }
    }
    private func metric(_ label: String,count: Int) -> some View {
        VStack(alignment:.leading,spacing:3) { Text("\(count)").font(.title3.weight(.semibold).monospacedDigit());Text(label).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct WelcomePanel: View {
    @ObservedObject var doc: Document
    let ctrl: SceneController
    var body: some View {
        VStack(spacing:18) {
            Image(systemName:"cube.transparent").font(.system(size:34,weight:.light)).foregroundStyle(Color.accentColor)
            VStack(spacing:9) {
                Text("Build your next project").font(.title2.weight(.semibold))
                Text("Design parts, add machining, and prepare your next CNC job.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            HStack(spacing:10) {
                Button("Choose a project preset…") { doc.showProjectPreset = true }
                Button("Open a project…") { doc.open();ctrl.zoomExtents() }.buttonStyle(.borderedProminent)
                Button("New plywood panel") { WorkspaceAction.addPanel.run(doc:doc,ctrl:ctrl) }
            }
            Divider()
            HStack {
                Button("Try a parametric bookcase") { doc.insertParametricBookcase();ctrl.zoomExtents() }.buttonStyle(.link)
                Spacer()
                Button("Import geometry…") { doc.importGeometry();ctrl.zoomExtents() }.buttonStyle(.link)
            }.font(.caption)
            Text("⌘K finds any command").font(.caption).foregroundStyle(.tertiary)
        }.padding(28).frame(maxWidth:440).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
    }
}
