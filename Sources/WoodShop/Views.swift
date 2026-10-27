import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var doc: Document
    let ctrl: SceneController
    @State private var addingStock = false
    var body: some View {
        HSplitView {
            if doc.showPartsSidebar { PartsSidebar(doc:doc,ctrl:ctrl).frame(minWidth:220,idealWidth:260,maxWidth:330) }
            HStack(spacing:0) {
                ToolPalette(doc:doc)
                Divider()
                VStack(spacing:0) {
                    SelectionBreadcrumbs(doc:doc)
                    ViewportView(doc:doc,ctrl:ctrl)
                        .overlay { if doc.parts.isEmpty { WelcomePanel(doc:doc,ctrl:ctrl) } }
                        .overlay(alignment:.topLeading) { ViewportHUD(doc:doc,ctrl:ctrl) }
                        .overlay { EditableDimensionOverlay(doc:doc,ctrl:ctrl) }
                    Divider()
                    StatusBar(doc:doc)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }.frame(minWidth:500)
            if doc.showInspector { Inspector(doc:doc).frame(minWidth:300,idealWidth:320,maxWidth:380).disabled(doc.parameterPreview != nil) }
        }
        .background { if doc.workspaceStore != nil { WorkspaceSplitRestoration().frame(width:0,height:0) } }
        .navigationTitle(doc.fileName)
        .navigationSubtitle(doc.isDirty ? "Edited" : "WoodShop")
        .background(WindowCloseGuard(doc:doc).frame(width:0,height:0))
        .toolbar {
            ToolbarItemGroup(placement:.navigation) {
                Button { doc.showPartsSidebar.toggle() } label: { Label("Parts",systemImage:"sidebar.left") }.help("Show or hide parts browser")
            }
            ToolbarItemGroup(placement:.principal) {
                Button { addingStock.toggle() } label: { Label("Add Stock",systemImage:"plus") }
                    .popover(isPresented:$addingStock) { StockPopover(doc:doc,ctrl:ctrl) }
                    .disabled(doc.workspaceInspectionOnly)
                Button { WorkspaceAction.sketchFace.run(doc:doc,ctrl:ctrl) } label: { Label("Sketch",systemImage:"pencil.and.outline") }.disabled(!WorkspaceAction.sketchFace.enabled(in:doc))
                Button { WorkspaceAction.machine.run(doc:doc,ctrl:ctrl) } label: { Label("Machine",systemImage:"hammer") }
                    .disabled(!WorkspaceAction.machine.enabled(in:doc))
                Button { doc.openMake(.prepare) } label: { Label("Make",systemImage:"square.grid.3x3") }.help("Prepare sheets, review machining, and export to VCarve")
            }
            ToolbarItemGroup(placement:.primaryAction) {
                Button { doc.showCommandPalette = true } label: { Image(systemName:"magnifyingglass") }.help("Search commands · ⌘K").accessibilityLabel("Search commands")
                Button { doc.showInspector.toggle() } label: { Label("Inspector",systemImage:"sidebar.right") }.help("Show or hide inspector")
            }
        }
        .sheet(isPresented:$doc.showCutList) { CutListView(doc:doc) }
        .sheet(isPresented:$doc.showWorkshop) { WorkshopView(doc:doc,ctrl:ctrl) }
        .sheet(isPresented:$doc.showDesign) { DesignPanel(doc:doc) }
        .sheet(isPresented:$doc.showFeatureEditor) { if let reference = doc.selectedFeature { FeatureEditorSheet(doc:doc,reference:reference) } }
        .sheet(isPresented:$doc.showCommandPalette) { WorkspaceCommandPalette(doc:doc,ctrl:ctrl) }
        .sheet(item:$doc.faceSketchRequest) { request in
            if let part = doc.part(request.part) {
                FaceSketchEditor(doc:doc,partID:part.id,initial:MachiningOperation(name:"Face sketch",axis:request.axis,positive:request.positive,depth:0.25,contour:[],sketch:FaceSketch.seed(part:part,axis:request.axis)))
            }
        }
        .sheet(item:$doc.dimensionRequest) { DimensionEditorSheet(doc:doc,request:$0) }
        .sheet(isPresented:$doc.showProjectPreset) { ProjectPresetSheet(doc:doc,ctrl:ctrl) }
        .sheet(isPresented:$doc.showMachiningRecipes) { MachiningRecipesSheet(doc:doc) }
        .onChange(of:doc.tool) { _,_ in doc.finishDrag?() }
        .onChange(of:doc.showPartsSidebar) { _,_ in doc.persistWorkspace() }
        .onChange(of:doc.showInspector) { _,_ in doc.persistWorkspace() }
        .onChange(of:doc.showEditableDimensions) { _,_ in doc.persistWorkspace() }
        .onChange(of:doc.partFilter) { _,_ in doc.persistWorkspace() }
        .onChange(of:doc.partSearch) { _,_ in doc.persistWorkspace() }
        .onChange(of:doc.metric) { _,_ in doc.persistWorkspace() }
        .onChange(of:doc.studio.setupProfile) { _,_ in doc.persistWorkspace() }
    }
}

struct ToolPalette: View {
    @ObservedObject var doc: Document
    var body: some View {
        VStack(spacing:5) {
            ForEach(Tool.allCases) { tool in
                Button { doc.tool = tool } label: {
                    VStack(spacing:4) { Image(systemName:tool.symbol).font(.system(size:17,weight:.medium));Text(tool == .select ? "␣" : tool.key).font(.system(size:9,weight:.medium,design:.rounded)).opacity(0.65) }.frame(width:42,height:48)
                }.buttonStyle(.plain)
                    .foregroundStyle(doc.tool == tool ? Color.accentColor : .secondary)
                    .background(doc.tool == tool ? Color.accentColor.opacity(0.12) : Color.clear,in:RoundedRectangle(cornerRadius:9))
                    .help(tool.title+" · "+tool.key).accessibilityLabel(tool.title).accessibilityAddTraits(doc.tool == tool ? .isSelected : [])
            }
            Spacer()
            Button { doc.showCommandPalette = true } label: { Image(systemName:"command").frame(width:42,height:38) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Search commands · ⌘K").accessibilityLabel("Search commands")
        }.padding(.horizontal,6).padding(.vertical,12).background(Color(nsColor:.windowBackgroundColor))
    }
}

struct StatusBar: View {
    @ObservedObject var doc: Document
    var body: some View {
        HStack {
            if doc.historyInspection != nil { Button("Resume full history") { doc.resumeFeatureHistory() } }
            if doc.parameterPreview != nil { Text("Parameter preview").foregroundStyle(.orange); Button("Discard preview") { doc.clearParameterPreview() } }
            Text(doc.status).lineLimit(1).font(.caption).frame(maxWidth:.infinity,alignment:.leading).layoutPriority(-1).help(doc.status)
            Spacer()
            if doc.activeDrag {
                TextField("Distance", text: $doc.exactDistance)
                    .frame(width: 95).textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if let value = Units.parse(doc.exactDistance, bareIsMM: doc.metric) { doc.applyDistance?(value) }
                        else { doc.status = "Enter a valid distance, such as 3 1/2 or 90mm." }
                    }
                    .onExitCommand { doc.cancelDrag?() }
                    .help("Type a signed distance and press Return. Move defaults to X unless an axis is locked.")
                Button("Cancel") { doc.cancelDrag?() }
            }
            Picker("Snap", selection: $doc.snap) {
                if doc.metric {
                    ForEach([0.5, 1, 2, 5, 10, 25], id: \.self) { value in Text("\(value, specifier: "%g") mm").tag(value / 25.4) }
                } else {
                    Text("1/32\"").tag(1.0 / 32); Text("1/16\"").tag(1.0 / 16); Text("1/8\"").tag(1.0 / 8)
                    Text("1/4\"").tag(0.25); Text("1/2\"").tag(0.5); Text("1\"").tag(1.0)
                }
            }.frame(width: 140)
            Toggle("Metric", isOn: $doc.metric)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var doc: Document
    var body: some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:8) {
                HStack { Text("Inspector").font(.headline);Spacer();if doc.selectedPart != nil { Image(systemName:doc.selectedPart?.hardware == true ? "wrench.and.screwdriver" : "cube").foregroundStyle(.secondary) } }
                if let part = doc.selectedPart {
                    Text(doc.selectedIDs.count > 1 ? "\(doc.selectedIDs.count) parts selected" : part.name).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(ShopIdentity.label(part)+"  ·  "+part.species.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Inspector section",selection:$doc.inspectorPage) { ForEach(InspectorPage.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                if let part = doc.selectedPart { InspectorSelectionActions(doc:doc,part:part) }
            }.padding(16)
            Divider()
            GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if doc.tool == .rectangle {
                        GroupBox("Draw a panel") {
                            VStack(alignment:.leading,spacing:8) { DimField(label:"Thickness",value:$doc.rectThickness,metric:doc.metric,minimum:1/32);Text("Drag on the ground or a flat face to draw the panel.").font(.caption).foregroundStyle(.secondary) }.padding(6)
                        }
                    }
                    if let p = doc.selectedPart {
                        switch doc.inspectorPage {
                        case .part:
                            if doc.selectedIDs.count > 1 { MultiSelectionInspector(doc:doc) }
                            else {
                                PartSection(doc:doc,part:p).id(p.id)
                                DisclosureGroup("Outline & curves") { ProfileSection(doc:doc,part:p) }
                                DisclosureGroup("Material & resizing") { MaterialIntentSection(doc:doc,part:p) }
                                if p.hardware != true { DisclosureGroup("Wood movement") { MovementSection(doc:doc,part:p) } }
                                DisclosureGroup("Linked dimensions") { RelationshipSection(doc:doc,part:p) }
                            }
                        case .machining:
                            if let feature = doc.selectedFeature,feature.part == p.id {
                                GroupBox("Selected feature") { VStack(alignment:.leading,spacing:8) { Text(p.featureName(FeatureStep(kind:feature.kind,feature:feature.feature))).font(.headline);Button("Edit feature…") { doc.showFeatureEditor = true } }.padding(6).frame(maxWidth:.infinity,alignment:.leading) }
                            }
                            CNCQuickActions(doc:doc,part:p)
                            if let face = doc.selectedFace,face.part == p.id {
                                Text("Selected face: \(face.label)").font(.headline)
                                JoinerySection(doc:doc,part:p,face:face).id("\(p.id)-\(face.axis)-\(face.positive)")
                                DisclosureGroup("Miter or bevel") { TrimSection(doc:doc,part:p,face:face) }
                                if p.hardware != true { DisclosureGroup("Pocket holes & edge profiles") { EdgeAndPocketSection(doc:doc,part:p,face:face) } }
                            } else { Text("Select a flat face in the model to add a pocket, dado, or tenon.").font(.callout).foregroundStyle(.secondary) }
                            if !p.cuts.isEmpty { DisclosureGroup("Existing joinery") { JoineryEditor(doc:doc,part:p) } }
                            if !p.trims.isEmpty { DisclosureGroup("Existing miters & bevels") { TrimEditor(doc:doc,part:p) } }
                            if p.hasEdgeProfiles { DisclosureGroup("Existing edge profiles") { ExistingEdges(doc:doc,part:p) } }
                        case .history:CompactFeatureHistory(doc:doc,part:p)
                        }
                    } else {
                        VStack(alignment:.leading,spacing:12) {
                            Image(systemName:"cursorarrow.click").font(.system(size:28)).foregroundStyle(.tertiary)
                            Text("Select a part").font(.title3.weight(.semibold))
                            Text("Click a part in the model or parts browser to see its dimensions, machining, and history.").foregroundStyle(.secondary)
                            Divider()
                            Button("Add a stock board") { doc.addStock() }
                            Button("Open workshop tools…") { doc.showWorkshop = true }
                            Button("Open materials and shop planning…") { doc.openMake(.materials) }
                            if doc.parts.isEmpty { Button("Start a parametric bookcase") { doc.insertParametricBookcase() } }
                        }.padding(.vertical,12)
                    }
                }.padding(16).frame(width:geometry.size.width,alignment:.leading)
            }
            }
        }.background(Color(nsColor:.windowBackgroundColor))
    }
}

private struct InspectorSelectionActions: View {
    @ObservedObject var doc: Document
    let part: Part
    private var woodSelection: Set<UUID> { Set(doc.parts.filter { doc.selectedIDs.contains($0.id) && $0.hardware != true }.map(\.id)) }
    private func makeSelection() { doc.cncPartIDs = woodSelection;doc.openMake(.prepare) }
    var body: some View {
        HStack(spacing:8) {
            if doc.selectedFeature?.part == part.id {
                Button("Edit feature") { doc.showFeatureEditor = true }.buttonStyle(.borderedProminent).disabled(doc.workspaceInspectionOnly)
            } else if doc.selectedFace?.part == part.id {
                Button("Sketch this face") { doc.beginFaceSketch() }.buttonStyle(.borderedProminent).disabled(doc.workspaceInspectionOnly)
            } else if doc.selectedIDs.count > 1 {
                Button("Make selection") { makeSelection() }.buttonStyle(.borderedProminent).disabled(woodSelection.isEmpty)
            } else {
                Button("Edit size") { doc.dimensionRequest = DimensionRequest(part:part.id,axis:part.materialAxes.l) }.buttonStyle(.borderedProminent).disabled(doc.workspaceInspectionOnly)
            }
            Menu("More") {
                Button("Parameters & history…") { doc.showDesign = true }
                Button("Machining tools…") { doc.showMachiningRecipes = true }
                Button("Materials & cost…") { doc.openMake(.materials) }
                Button("Hardware patterns…") { doc.openMake(.hardware) }
                Button("Prepare selected parts for CNC…") { makeSelection() }.disabled(woodSelection.isEmpty)
            }
        }.font(.callout)
    }
}

struct PartSection: View {
    @ObservedObject var doc: Document
    let part: Part
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    private func bind(_ kp: WritableKeyPath<Part,Double>,min: Double? = nil) -> Binding<Double> {
        Binding(get:{doc.part(part.id)?[keyPath:kp] ?? 0},set:{ value in doc.edit(part.id) { $0[keyPath:kp] = min.map { Swift.max($0,value) } ?? value } })
    }
    private func sizeLabel(_ axis: Int) -> String {
        let axes = part.materialAxes
        return (axis == axes.t ? "Thickness" : (axis == axes.l ? "Length" : "Width"))+" ("+FaceRef.axisNames[axis]+")"
    }
    private func driven(_ target: BindingTarget,_ axis: Int) -> Bool {
        (part.bindings ?? []).contains { $0.target == target && $0.axis == axis } || (target == .size && doc.links.contains { $0.target == part.id && $0.targetAxis == axis })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:7) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Part name",text:$name).textFieldStyle(.roundedBorder).focused($nameFocused).onSubmit(commitName).accessibilityLabel("Part name")
                    .onExitCommand { name = doc.part(part.id)?.name ?? part.name;nameFocused = false }
            }
            Picker("Material",selection:Binding(get:{doc.part(part.id)?.species ?? .oak},set:{ value in doc.edit(part.id) { $0.species = value } })) { ForEach(Species.allCases.filter { !$0.isHardware || $0 == part.species }) { Text($0.rawValue).tag($0) } }
            GroupBox("Dimensions") {
                VStack(alignment:.leading,spacing:10) {
                    DimField(label:sizeLabel(0),value:bind(\.size.x,min:1/32),metric:doc.metric,minimum:1/32).disabled(driven(.size,0))
                    DimField(label:sizeLabel(1),value:bind(\.size.y,min:1/32),metric:doc.metric,minimum:1/32).disabled(driven(.size,1))
                    DimField(label:sizeLabel(2),value:bind(\.size.z,min:1/32),metric:doc.metric,minimum:1/32).disabled(driven(.size,2))
                    if (0..<3).contains(where: { driven(.size,$0) }) {
                        Label("Dimensions follow parameters or linked parts.",systemImage:"link").font(.caption).foregroundStyle(.secondary)
                        Button("Edit driving parameters…") { doc.showDesign = true }
                    }
                }.padding(7)
            }
            DisclosureGroup("Position") {
                VStack(spacing:9) {
                    DimField(label:"X",value:bind(\.origin.x),metric:doc.metric).disabled(driven(.position,0))
                    DimField(label:"Y (up)",value:bind(\.origin.y),metric:doc.metric).disabled(driven(.position,1))
                    DimField(label:"Z",value:bind(\.origin.z),metric:doc.metric).disabled(driven(.position,2))
                }.padding(.top,8)
            }
            DisclosureGroup("Rotation") {
                VStack(alignment:.leading,spacing:9) {
                    AngleField(label:"About X",value:bind(\.rot.x)).disabled(driven(.rotation,0))
                    AngleField(label:"About Y",value:bind(\.rot.y)).disabled(driven(.rotation,1))
                    AngleField(label:"About Z",value:bind(\.rot.z)).disabled(driven(.rotation,2))
                    HStack { Text("Turn 90°").font(.caption).foregroundStyle(.secondary);ForEach(0..<3) { axis in Button(FaceRef.axisNames[axis]) { doc.rotateSelected(axis:axis) }.disabled(part.isRotated) } }
                }.padding(.top,8)
            }
        }
        .onAppear { name = part.name;if doc.renamePartID == part.id { nameFocused = true } }
        .onChange(of:part.name) { _,value in if !nameFocused { name = value } }
        .onChange(of:doc.renamePartID) { _,id in if id == part.id { nameFocused = true;doc.renamePartID = nil } }
        .onChange(of:nameFocused) { _,focused in if !focused { commitName() } }
    }
    private func commitName() {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { name = doc.part(part.id)?.name ?? part.name;doc.status = "Enter a name for this part.";return }
        if doc.part(part.id)?.name != trimmed { doc.edit(part.id) { $0.name = trimmed } }
        name = trimmed
    }
}

// MARK: - Joinery

struct JoinerySection: View {
    @ObservedObject var doc: Document
    let part: Part
    let face: FaceRef

    enum Kind: String, CaseIterable { case dado = "Dado", rabbet = "Rabbet", mortise = "Mortise", groove = "Groove", tenon = "Tenon" }
    @State private var kind = Kind.dado
    @State private var runAlongFirst = true
    @State private var fromFar = false
    @State private var offset = 0.0
    @State private var width = 0.75
    @State private var depth = 0.25
    @State private var length = 0.0

    private var u: Int { (face.axis + 1) % 3 }
    private var v: Int { (face.axis + 2) % 3 }
    private var run: Int { runAlongFirst ? u : v }
    private var across: Int { runAlongFirst ? v : u }

    var body: some View {
        GroupBox("Joinery on face \(face.label)") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Type", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .onChange(of: kind) { _, k in
                        if k == .rabbet { offset = 0 }
                        length = k == .mortise || k == .tenon ? 2 : 0
                    }
                Picker("Runs along", selection: $runAlongFirst) {
                    Text(FaceRef.axisNames[u]).tag(true); Text(FaceRef.axisNames[v]).tag(false)
                }.pickerStyle(.segmented)
                Toggle("Measure offset from far edge", isOn: $fromFar)
                DimField(label: "Offset", value: $offset, metric: doc.metric, minimum: 0)
                DimField(label: "Width", value: $width, metric: doc.metric, minimum: 1 / 1024)
                DimField(label: kind == .tenon ? "Tenon length" : "Depth", value: $depth, metric: doc.metric, minimum: 1 / 1024)
                DimField(label: "Length", value: $length, metric: doc.metric, minimum: 0)
                Text(kind == .tenon ? "Tenon sticks out of the selected end face; length 0 = full width."
                     : "Length 0 = full length (dado, rabbet); otherwise centred (mortise).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Add \(kind.rawValue)") { addCut() }
                if !part.cuts.isEmpty {
                    Divider()
                    ForEach(part.cuts) { c in
                        HStack {
                            Text("\(c.kind)  \(doc.fmt(c.hi.x - c.lo.x)) × \(doc.fmt(c.hi.y - c.lo.y)) × \(doc.fmt(c.hi.z - c.lo.z))")
                                .font(.caption)
                            Spacer()
                            Button { doc.edit(part.id) { $0.cuts.removeAll { $0.id == c.id } } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }.padding(4)
        }
    }

    private func addCut() {
        let a = face.axis
        var lo = SIMD3<Double>.zero, hi = part.size
        // Depth into the part from the chosen face (a tenon instead sticks out of it).
        if kind == .tenon {
            if face.positive { lo[a] = part.size[a]; hi[a] = part.size[a] + depth } else { lo[a] = -depth; hi[a] = 0 }
        } else if face.positive { lo[a] = part.size[a] - depth } else { hi[a] = depth }
        // Position across the run direction.
        if fromFar { hi[across] = part.size[across] - offset; lo[across] = hi[across] - width }
        else { lo[across] = offset; hi[across] = offset + width }
        // Extent along the run direction.
        if length > 0 {
            lo[run] = (part.size[run] - length) / 2
            hi[run] = lo[run] + length
        }
        for i in 0..<3 where !(kind == .tenon && i == a) {
            lo[i] = max(lo[i], 0); hi[i] = min(hi[i], part.size[i])
        }
        guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else {
            doc.status = "That cut falls outside the board."
            return
        }
        doc.edit(part.id) { $0.cuts.append(Cut(kind: kind.rawValue, lo: lo, hi: hi, faceAxis: a, facePositive: face.positive, runAxis: run, offsetFromFar: fromFar)) }
        doc.status = "\(kind.rawValue) added."
    }
}

struct TrimSection: View {
    @ObservedObject var doc: Document
    let part: Part
    let face: FaceRef
    @State private var angle = 45.0
    @State private var runFirst = true
    @State private var farEdge = false

    private var u: Int { (face.axis + 1) % 3 }
    private var v: Int { (face.axis + 2) % 3 }

    var body: some View {
        GroupBox("Miter / bevel on face \(face.label)") {
            VStack(alignment: .leading, spacing: 6) {
                AngleField(label: "Angle", value: $angle, limit: 89.899)
                Picker("Tilt about", selection: $runFirst) {
                    Text(FaceRef.axisNames[u]).tag(true); Text(FaceRef.axisNames[v]).tag(false)
                }.pickerStyle(.segmented)
                Toggle("Long point on far edge", isOn: $farEdge)
                Text("Tilt about the board's thickness axis for a miter, or its width axis for a bevel.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Add Angled Cut") {
                    let t = Trim(axis: face.axis, positive: face.positive, run: runFirst ? u : v, angle: angle, farEdge: farEdge)
                    doc.edit(part.id) { $0.trims.append(t) }
                    doc.status = "Angled cut added."
                }
                ForEach(part.trims) { t in
                    HStack {
                        Text("\(FaceRef(part: part.id, axis: t.axis, positive: t.positive).label)  \(String(format: "%g", t.angle))°")
                            .font(.caption)
                        Spacer()
                        Button { doc.edit(part.id) { $0.trims.removeAll { $0.id == t.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }.padding(4)
        }
    }
}

// MARK: - Fields

struct AngleField: View {
    let label: String
    @Binding var value: Double
    var limit: Double = 1_000_000
    @State private var text = ""
    @State private var lastFormatted = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).frame(width: 65, alignment: .leading)
                TextField("", text: $text).textFieldStyle(.roundedBorder).focused($focused).onSubmit(commit)
                    .accessibilityLabel(label)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear(perform: refresh)
        .onChange(of: value) { _, _ in if !focused { refresh() } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }
    private func refresh() { text = String(format: "%g°", value); lastFormatted = text; error = nil }
    private func commit() {
        if text == lastFormatted { refresh(); return }
        guard let v = Double(text.replacingOccurrences(of: "°", with: "").trimmingCharacters(in: .whitespaces)),
              v.isFinite, abs(v) <= limit else { error = "Enter a finite angle within ±\(limit)°."; return }
        if abs(v - value) > 1e-9 { value = v }
        refresh()
    }
}

struct DimField: View {
    let label: String
    @Binding var value: Double
    let metric: Bool
    var minimum: Double? = nil
    @State private var inputMetric = false
    @State private var text = ""
    @State private var lastFormatted = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).frame(width: label.count > 4 ? 90 : 52, alignment: .leading)
                TextField("", text: $text).textFieldStyle(.roundedBorder).focused($focused).onSubmit(commit)
                    .accessibilityLabel(label)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear(perform: refresh)
        .onChange(of: value) { _, _ in if !focused { refresh() } }
        .onChange(of: metric) { _, _ in if !focused { refresh() } }
        .onChange(of: focused) { _, f in if f { inputMetric = metric } else { commit() } }
    }
    private func refresh() { inputMetric = metric; text = Units.format(value, metric: metric); lastFormatted = text; error = nil }
    private func commit() {
        if text == lastFormatted { refresh(); return }
        guard let v = Units.parse(text, bareIsMM: inputMetric), v.isFinite else { error = "Enter a valid measurement."; return }
        if let minimum, v < minimum { error = "Minimum: \(Units.format(minimum, metric: metric))"; return }
        if abs(v - value) > 1e-9 { value = v }
        refresh()
    }
}

// MARK: - Cut list

