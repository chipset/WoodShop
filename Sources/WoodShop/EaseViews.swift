import SwiftUI

struct ProjectPresetSheet: View {
    @ObservedObject var doc: Document
    let ctrl: SceneController
    @Environment(\.dismiss) private var dismiss
    @State private var kind = WoodworkingPreset.cabinet
    @State private var dimensions = PresetDimensions()
    private var validation: String? {
        do { _ = try PresetBuilder.build(kind,dimensions:dimensions,prefix:"preview",group:"Preview");return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Start with a woodworking project").font(.title2.bold())
            Picker("Project",selection:$kind) { ForEach(WoodworkingPreset.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Text(kind == .drawer ? "Width is the cabinet opening. Clearance is reserved on each side for your drawer slides." : "These dimensions become named parameters so the whole assembly can be resized later.").foregroundStyle(.secondary)
            HStack {
                DimField(label:kind == .drawer || kind == .shelf ? "Opening width" : "Width",value:$dimensions.width,metric:doc.metric,minimum:1/32)
                DimField(label:"Depth",value:$dimensions.depth,metric:doc.metric,minimum:1/32)
            }
            if kind != .shelf { DimField(label:"Height",value:$dimensions.height,metric:doc.metric,minimum:1/32) }
            DimField(label:"Material thickness",value:$dimensions.thickness,metric:doc.metric,minimum:1/32)
            if kind == .drawer || kind == .cabinet {
                HStack {
                    DimField(label:kind == .drawer ? "Bottom thickness" : "Back thickness",value:$dimensions.backThickness,metric:doc.metric,minimum:1/32)
                    DimField(label:kind == .drawer ? "Bottom inset" : "Back inset",value:$dimensions.inset,metric:doc.metric,minimum:0)
                }
            }
            if kind == .drawer || kind == .shelf { DimField(label:"Clearance per side",value:$dimensions.clearance,metric:doc.metric,minimum:0) }
            if let validation { Text(validation).font(.callout).foregroundStyle(.red) }
            Text(kind == .bench ? "Creates a top, four square legs, and a lower shelf. Add fastening and joinery for your construction method." : "Creates assembled stock. Use machining recipes to add the joints and hardware holes you need.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create project parts") { if doc.insertPreset(kind,dimensions:dimensions) { ctrl.zoomSelection();dismiss() } }.buttonStyle(.borderedProminent).disabled(validation != nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:640,height:490).background(Color(nsColor:.windowBackgroundColor))
        .onChange(of:kind) { _,value in
            switch value {
            case .drawer: dimensions.height = 6;dimensions.depth = 20;dimensions.thickness = 0.5
            case .cabinet: dimensions = PresetDimensions()
            case .shelf: dimensions.depth = 12;dimensions.clearance = 1/32;dimensions.thickness = 0.75
            case .bench: dimensions.width = 60;dimensions.height = 35;dimensions.depth = 30;dimensions.thickness = 1.5
            }
        }
    }
}

struct DimensionEditorSheet: View {
    @ObservedObject var doc: Document
    let request: DimensionRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var report: ParameterPreview?
    @State private var error = ""
    @State private var baseline: Project?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Edit dimension").font(.title2.bold())
            if let part = doc.part(request.part) {
                Text(part.name+" · "+FaceRef.axisNames[request.axis]).font(.headline)
                if let driver = DimensionChange.driver(baseline ?? doc.project,request) { Label("Driven by "+driver,systemImage:"link").font(.callout).foregroundStyle(.secondary) }
            }
            TextField("New size",text:$text).textFieldStyle(.roundedBorder).font(.title3).focused($focused).onSubmit(preview)
                .onChange(of:text) { _,_ in report = nil;error = "";doc.clearParameterPreview() }
            Text("Use inches or millimeters: 24 1/2\", 622 mm. Preview updates the model before you apply it.").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.callout) }
            if let report { Text("\(report.affected.count) part(s) will update.").foregroundStyle(.secondary) }
            Spacer()
            HStack {
                Button("Parameters…") { dismiss();DispatchQueue.main.async { doc.showDesign = true } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Preview") { preview() }
                Button("Apply") { if let report,doc.applyDimensionPreview(report) { dismiss() } }.buttonStyle(.borderedProminent).disabled(report?.canApply != true)
            }
        }.padding(24).frame(width:510,height:340).background(Color(nsColor:.windowBackgroundColor))
        .onAppear { baseline = doc.project;text = doc.part(request.part).map { doc.fmt($0.size[request.axis]) } ?? "";focused = true }
        .onDisappear { doc.clearParameterPreview() }
    }
    private func preview() {
        guard let baseline else { return }
        do {
            let value = try DimensionChange.preview(baseline,request:request,text:text)
            guard value.canApply else { throw ModelValidation.Failure(message:value.conflicts.map(\.message).joined(separator:"\n")) }
            report = value;doc.parameterPreview = value.project;doc.previewAffected = Set(value.affected);error = ""
        } catch { report = nil;doc.clearParameterPreview();self.error = error.localizedDescription }
    }
}

struct MachiningRecipesSheet: View {
    @ObservedObject var doc: Document
    @Environment(\.dismiss) private var dismiss
    @State private var recipe: MachiningRecipe?
    @State private var pattern: DrillingPattern?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Machine your part").font(.title2.bold())
            Text(doc.selectedPart.map { ShopIdentity.label($0)+" · "+$0.name } ?? "Select a part to add machining.").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing:10) {
                    ForEach(MachiningRecipe.allCases) { item in
                        Button {
                            if let part = doc.selectedPart,item == .shelfPins || item == .hingeCups { pattern = item.pattern(part:part,face:doc.selectedFace) }
                            recipe = item
                        } label: {
                            HStack {
                                VStack(alignment:.leading,spacing:5) { Text(item.rawValue).font(.headline);Text(item.detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                                Spacer();Image(systemName:"chevron.right").foregroundStyle(.secondary)
                            }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
                        }.buttonStyle(.plain).disabled(doc.selectedPart == nil)
                    }
                }
            }
            HStack {
                Button("All machining tools…") { dismiss();DispatchQueue.main.async { doc.workshopTab = 0;doc.showWorkshop = true } }
                Spacer();Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width:650,height:510).background(Color(nsColor:.windowBackgroundColor))
        .sheet(item:$recipe) { item in
            if item == .dado { MatingJointWizard(doc:doc) }
            else if item == .dogbones { ReliefRecipeSheet(doc:doc) }
            else if let pattern,let part = doc.selectedPart {
                PatternRecipeSheet(doc:doc,partID:part.id,pattern:pattern,detail:item.detail)
            }
        }
    }
}

struct PatternRecipeSheet: View {
    @ObservedObject var doc: Document
    let partID: UUID
    let pattern: DrillingPattern
    let detail: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(pattern.name).font(.title2.bold());Text(detail).foregroundStyle(.secondary)
            ScrollView { PatternEditor(doc:doc,partID:partID,initial:pattern).padding(4) }
            HStack { StatusMessage(doc:doc).font(.caption).foregroundStyle(.secondary).lineLimit(2);Spacer();Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width:760,height:740).background(Color(nsColor:.windowBackgroundColor))
    }
}

struct ReliefRecipeSheet: View {
    @ObservedObject var doc: Document
    @Environment(\.dismiss) private var dismiss
    @State private var style = ReliefStyle.dogbone
    @State private var diameter = 0.25
    @State private var report: ParameterPreview?
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Add corner relief").font(.title2.bold())
            Text("Preview relief on active rectangular pockets in the selected part. Linked dados keep their mating relationships.").foregroundStyle(.secondary)
            Picker("Relief",selection:$style) { ForEach(ReliefStyle.allCases.filter { $0 != .none }) { Text($0.rawValue).tag($0) } }
            DimField(label:"Cutter diameter",value:$diameter,metric:doc.metric,minimum:0.001)
            Text(message).font(.callout).foregroundStyle(report == nil ? Color.red : .secondary)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer();Button("Preview") { preview() }
                Button("Apply relief") { if let report,doc.applyDimensionPreview(report,historyTitle:"Add corner relief") { doc.status = "Added corner relief. Cutter compensation is applied in VCarve.";dismiss() } }.buttonStyle(.borderedProminent).disabled(report == nil)
            }
        }.padding(24).frame(width:520,height:330).background(Color(nsColor:.windowBackgroundColor))
        .onAppear { diameter = doc.studio.setupProfile?.defaultTool?.diameter ?? 0.25 }
        .onChange(of:diameter) { _,_ in clear() }.onChange(of:style) { _,_ in clear() }
        .onDisappear { doc.clearParameterPreview() }
    }
    private func clear() { report = nil;message = "";doc.clearParameterPreview() }
    private func preview() {
        guard let id = doc.selection else { return }
        do {
            let value = try ReliefRecipe.preview(doc.project,partID:id,style:style,diameter:diameter)
            report = value;doc.parameterPreview = value.project;doc.previewAffected = Set(value.affected);message = "Preview ready. Review the corners, then apply."
        } catch { clear();message = error.localizedDescription }
    }
}

struct SelectionBreadcrumbs: View {
    @ObservedObject var doc: Document
    var body: some View {
        if let part = doc.selectedPart {
            HStack(spacing:5) {
                let segments = (part.group ?? "").split(separator:"/").map(String.init)
                ForEach(Array(segments.enumerated()),id:\.offset) { index,name in
                    Button(name) { doc.selectAssembly(segments.prefix(index+1).joined(separator:"/")) }.buttonStyle(.plain).lineLimit(1)
                    Image(systemName:"chevron.right").font(.system(size:8))
                }
                Text(part.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength:0)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,14).padding(.vertical,8).background(.bar)
        }
    }
}

struct EditableDimensionOverlay: View {
    @ObservedObject var doc: Document
    @ObservedObject var ctrl: SceneController
    var body: some View {
        GeometryReader { geometry in
            if doc.showEditableDimensions,doc.selectedIDs.count == 1,let part = doc.selectedPart,doc.tool == .select {
                let dimensions = positions(part,size:geometry.size)
                Canvas { context,_ in
                    for item in dimensions {
                        var path = Path();path.move(to:item.a);path.addLine(to:item.b)
                        let dx = item.b.x-item.a.x,dy = item.b.y-item.a.y,length = max(1,hypot(dx,dy))
                        let normal = CGPoint(x:-dy/length*4,y:dx/length*4)
                        for p in [item.a,item.b] { path.move(to:CGPoint(x:p.x-normal.x,y:p.y-normal.y));path.addLine(to:CGPoint(x:p.x+normal.x,y:p.y+normal.y)) }
                        path.move(to:CGPoint(x:(item.a.x+item.b.x)/2,y:(item.a.y+item.b.y)/2));path.addLine(to:item.point)
                        context.stroke(path,with:.color(.accentColor.opacity(0.7)),lineWidth:1)
                    }
                }.allowsHitTesting(false)
                ForEach(dimensions,id:\.axis) { item in
                    Button { doc.dimensionRequest = DimensionRequest(part:part.id,axis:item.axis) } label: {
                        HStack(spacing:4) {
                            if DimensionChange.driver(doc.project,DimensionRequest(part:part.id,axis:item.axis)) != nil { Image(systemName:"link").font(.caption2) }
                            Text(item.label).font(.caption.monospacedDigit())
                        }.padding(.horizontal,8).padding(.vertical,5).background(.regularMaterial,in:Capsule())
                    }.buttonStyle(.plain).foregroundStyle(Color.accentColor).position(item.point)
                        .help("Click to edit "+FaceRef.axisNames[item.axis]+" dimension").disabled(doc.workspaceInspectionOnly)
                }
            }
        }
    }
    private struct Position { var axis: Int;var point: CGPoint;var a: CGPoint;var b: CGPoint;var label: String }
    private func positions(_ part: Part,size: CGSize) -> [Position] {
        let center = ctrl.screenPoint(part.center,size:size)
        return (0..<3).compactMap { axis in
            var a = SIMD3<Double>.zero,b = SIMD3<Double>.zero;b[axis] = part.size[axis]
            // Place the dimension beside the outside edge of the stock.
            for other in 0..<3 where other != axis { a[other] = -0.05*part.size[other];b[other] = a[other] }
            guard let p = ctrl.screenPoint(part.toWorld(a),size:size),let q = ctrl.screenPoint(part.toWorld(b),size:size),let center else { return nil }
            guard hypot(q.x-p.x,q.y-p.y) > 35 else { return nil }
            let middle = CGPoint(x:(p.x+q.x)/2,y:(p.y+q.y)/2)
            let dx = middle.x-center.x,dy = middle.y-center.y,length = max(1,hypot(dx,dy))
            let point = CGPoint(x:middle.x+dx/length*22,y:middle.y+dy/length*22)
            guard point.x > 45,point.y > 60,point.x < size.width-45,point.y < size.height-40 else { return nil }
            return Position(axis:axis,point:point,a:p,b:q,label:FaceRef.axisNames[axis]+" "+doc.fmt(part.size[axis]))
        }
    }
}
