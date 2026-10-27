import SwiftUI
import SceneKit

enum FaceSketchTool: String,CaseIterable,Identifiable {
    case select = "Select",rectangle = "Rectangle",ellipse = "Ellipse",arc = "Arc",line = "Line",pen = "Pen",pan = "Pan"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .select:return "cursorarrow";case .rectangle:return "rectangle";case .ellipse:return "circle";case .arc:return "circle.lefthalf.filled";case .line:return "line.diagonal";case .pen:return "point.topleft.down.curvedto.point.bottomright.up";case .pan:return "hand.draw" }
    }
    var hint: String {
        switch self {
        case .select:return "Drag the center to move a shape. Select a path point to edit its blue curve handles."
        case .pen:return "Click to add connected points. Select a point and choose Curve to bend the next edge. Finish path when ready."
        case .pan:return "Drag to pan the face. Use Fit to restore the whole board."
        default:return "Drag on the face to draw. Hold Shift to constrain the proportions or direction."
        }
    }
}

struct FaceSketchEditor: View {
    @ObservedObject var doc: Document
    let partID: UUID
    let initial: MachiningOperation
    @Environment(\.dismiss) private var dismiss
    @State private var sketch: FaceSketch
    @State private var name: String
    @State private var enabled: Bool
    @State private var toolID: UUID?
    @State private var tool = FaceSketchTool.select
    @State private var selected: Int?
    @State private var snap = true
    @State private var baseline: Project?
    @State private var report: ParameterPreview?
    @State private var error = ""
    @State private var undo: [FaceSketch] = []
    @State private var redo: [FaceSketch] = []
    @State private var gestureBefore: FaceSketch?
    @State private var bindingField = SketchDimension.width
    @State private var expression = ""
    @State private var preview3D = false
    @State private var constraintKind = SketchConstraintKind.horizontal
    @State private var constraintReference = 0
    @State private var constraintLength = 1.0
    @State private var cornerRadius = 0.25
    @State private var snapGeometry: SketchSnapGeometry?
    init(doc:Document,partID:UUID,initial:MachiningOperation) {
        self.doc = doc;self.partID = partID;self.initial = initial
        _sketch = State(initialValue:initial.sketch ?? doc.part(partID).map { FaceSketch.seed(part:$0,axis:initial.axis) } ?? FaceSketch())
        _name = State(initialValue:initial.name);_enabled = State(initialValue:initial.suppressed != true)
        _toolID = State(initialValue:doc.part(partID)?.toolAssignments?[initial.id.uuidString])
    }
    private var part: Part? { doc.part(partID) }
    private var faceSize: SIMD2<Double> { part.map { SIMD2($0.size[initial.u],$0.size[initial.v]) } ?? SIMD2(repeating:1) }
    private var evaluated: FaceSketch { (try? sketch.resolved(values:Parametric.values((baseline ?? doc.project).studio?.parameters ?? []),operation:initial,stock:part?.size ?? SIMD3(repeating:1),references:part?.operations ?? [])) ?? sketch }
    private var generated: Result<MachiningOperation,Error> {
        Result {
            guard let part else { throw ModelValidation.Failure(message:"The part was removed.") }
            var op = initial;op.name = name;op.suppressed = !enabled;op.sketch = sketch
            return try sketch.generated(from:op,size:part.size,values:Parametric.values((baseline ?? doc.project).studio?.parameters ?? []),references:part.operations ?? [])
        }
    }
    var body: some View {
        VStack(spacing:0) {
            header
            Divider()
            HStack(spacing:0) {
                VStack(spacing:0) {
                    tools
                    Divider()
                    if preview3D,let candidate = report?.project?.parts.first(where: { $0.id == partID }) {
                        SketchResultPreview(part:candidate,axis:initial.axis,positive:initial.positive).overlay(alignment:.bottomLeading) { Text("Drag to orbit · Scroll to zoom").font(.caption).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).padding(12) }
                    } else {
                        FaceSketchCanvas(sketch:$sketch,selected:$selected,tool:$tool,evaluated:evaluated,snapGeometry:snapGeometry,faceSize:faceSize,profile:part?.profile,partSize:part?.size ?? SIMD3(repeating:1),axis:initial.axis,snap:snap ? doc.snap : nil,metric:doc.metric,onBegin:beginGesture,onEnd:endGesture)
                    }
                    Divider()
                    HStack { Text(preview3D ? "Preview of the regenerated part" : tool.hint).lineLimit(2);Spacer();Text("U = \(FaceRef.axisNames[initial.u]) · V = \(FaceRef.axisNames[initial.v])").fixedSize() }.font(.caption).foregroundStyle(.secondary).padding(12)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                ScrollView { controls.padding(16) }.frame(width:300)
            }
            Divider()
            footer
        }.frame(width:1060,height:780).background(Color(nsColor:.windowBackgroundColor))
        .onAppear { baseline = doc.project;doc.faceSketchEditorActive = true;if let part { snapGeometry = SketchSnapGeometry(part:part,axis:initial.axis,excluding:initial.id) } }
        .onChange(of:sketch) { _,_ in invalidate() }
        .onChange(of:name) { _,_ in invalidate() }
        .onChange(of:enabled) { _,_ in invalidate() }
        .onChange(of:toolID) { _,_ in invalidate() }
        .onDisappear { doc.clearParameterPreview();doc.faceSketchEditorActive = false }
        .onExitCommand { if tool == .pen { tool = .select } else { dismiss() } }
    }
    private var header: some View {
        HStack(spacing:14) {
            Image(systemName:"pencil.and.outline").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment:.leading,spacing:3) {
                Text("Sketch on face").font(.title2.bold())
                Text((part.map { ShopIdentity.label($0)+" · "+$0.name } ?? "Removed part")+" · "+(initial.positive ? "+" : "−")+FaceRef.axisNames[initial.axis]+" face").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if report != nil { Picker("Preview",selection:$preview3D) { Text("Face sketch").tag(false);Text("3D result").tag(true) }.pickerStyle(.segmented).frame(width:200) }
        }.padding(20)
    }
    private var tools: some View {
        HStack(spacing:4) {
            ForEach(FaceSketchTool.allCases) { item in
                Button { choose(item) } label: {
                    VStack(spacing:4) { Image(systemName:item.symbol);Text(item.rawValue).font(.caption2) }.frame(width:54,height:43)
                }.buttonStyle(.plain).foregroundStyle(tool == item ? Color.accentColor : .secondary)
                    .background(tool == item ? Color.accentColor.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:7)).help(item.hint).accessibilityLabel(item.rawValue)
            }
            Spacer(minLength:4)
            Button { if let previous = undo.popLast() { redo.append(sketch);sketch = previous;selected = nil } } label: { Image(systemName:"arrow.uturn.backward") }.disabled(undo.isEmpty).keyboardShortcut("z",modifiers:.command).help("Undo sketch edit")
            Button { if let next = redo.popLast() { undo.append(sketch);sketch = next;selected = nil } } label: { Image(systemName:"arrow.uturn.forward") }.disabled(redo.isEmpty).keyboardShortcut("z",modifiers:[.command,.shift]).help("Redo sketch edit")
        }.padding(10).disabled(preview3D)
    }
    private var controls: some View {
        VStack(alignment:.leading,spacing:16) {
            TextField("Feature name",text:$name).textFieldStyle(.roundedBorder).accessibilityLabel("Sketch feature name")
            Picker("Shape",selection:Binding(get:{sketch.shape},set:{ shape in change { s in if shape == .path && s.shape != .path { s.nodes = s.shapeNodes();s.closed = s.isClosed };s.shape = shape;s.constraints = nil;s.keepCircular = nil;if !s.isClosed { s.mode = .groove;s.islandInset = nil } };selected = nil;tool = .select })) { ForEach(FaceSketchShape.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Cut",selection:Binding(get:{sketch.mode},set:{ mode in change { $0.mode = mode;if mode != .pocket { $0.islandInset = nil } } })) { ForEach(FaceSketchMode.allCases) { Text($0.rawValue).tag($0) } }
            if sketch.mode == .through { Text("Cuts through this face’s full stock thickness and follows thickness changes.").font(.caption).foregroundStyle(.secondary) }
            else { dimension(.depth) }
            if sketch.mode == .groove { dimension(.grooveWidth);if sketch.isClosed { Text("Closed groove: the middle remains solid. Both pocket boundaries export together.").font(.caption).foregroundStyle(.secondary) } }
            if sketch.mode == .pocket && sketch.isClosed {
                Toggle("Preserve raised center island",isOn:Binding(get:{sketch.islandInset != nil},set:{ value in change { $0.islandInset = value ? min($0.size.x,$0.size.y)/6 : nil } }))
                if let inset = sketch.islandInset { DimField(label:"Pocket border width",value:Binding(get:{inset},set:{ value in change { $0.islandInset = value } }),metric:doc.metric,minimum:0.001) }
            }
            Divider()
            Text(sketch.shape == .path ? "Path frame" : "Shape dimensions").font(.headline)
            dimension(.centerU);dimension(.centerV);dimension(.width);dimension(.height)
            if sketch.shape == .arc { dimension(.start);dimension(.sweep) }
            if sketch.shape == .roundedRectangle || sketch.shape == .chamferedRectangle { dimension(.corner) }
            if sketch.shape == .ellipse { Toggle("Keep circular",isOn:Binding(get:{sketch.keepCircular == true},set:{ value in change { $0.keepCircular = value } })) }
            Picker("Concentric with",selection:Binding(get:{sketch.concentricWith},set:{ value in change { $0.concentricWith = value } })) {
                Text("Independent center").tag(nil as UUID?)
                ForEach((part?.operations ?? []).filter { $0.id != initial.id && $0.axis == initial.axis }) { op in Text(op.name).tag(Optional(op.id)) }
            }
            if sketch.shape != .path {
                Button("Edit as Bézier path") {
                    change { s in let closed = s.isClosed;s.nodes = s.shapeNodes();s.shape = .path;s.closed = closed;s.keepCircular = nil }
                    selected = 0;tool = .select
                }
            }
            if sketch.orientation != SketchOrientation() { Text("Dimensions use the sketch’s original frame; the canvas shows its current rotated or mirrored face.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Scale sketch with the board",isOn:Binding(get:{sketch.scaleWithFace},set:{ value in change { $0.scaleWithFace = value } }))
            Text(sketch.scaleWithFace ? "Placement and shape scale with the face. Groove width and cutting depth remain explicit." : "Placement and shape stay at their entered sizes when the board is resized.").font(.caption).foregroundStyle(.secondary)
            if sketch.shape == .path { pathControls;constraintControls }
            Divider()
            Toggle("Snap to grid",isOn:$snap)
            Text("Snap: "+doc.fmt(doc.snap)+". Hold Option while dragging for free movement.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Drive dimensions with parameters") {
                VStack(alignment:.leading,spacing:9) {
                    ForEach(sketch.expressions) { binding in
                        HStack(alignment:.top) {
                            Text(binding.field.rawValue+" = "+binding.expression).font(.caption)
                            Spacer();Button { change { $0.expressions.removeAll { $0.field == binding.field } } } label: { Image(systemName:"link.badge.plus") }.help("Unlink dimension")
                        }
                    }
                    Picker("Dimension",selection:$bindingField) { ForEach(SketchDimension.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("e.g. thickness / 2",text:$expression).textFieldStyle(.roundedBorder)
                    Button("Use expression") {
                        change { s in s.expressions.removeAll { $0.field == bindingField };s.expressions.append(SketchExpression(field:bindingField,expression:expression,metricLiterals:doc.metric)) }
                    }.disabled(expression.trimmingCharacters(in:.whitespaces).isEmpty)
                    Text("Named parameters regenerate the sketch and its machining together.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top,8)
            }
            GroupBox("Cutter for this feature") {
                VStack(alignment:.leading,spacing:8) {
                    Picker("Tool",selection:$toolID) {
                        Text("Setup default").tag(nil as UUID?)
                        ForEach(doc.studio.setupProfile?.tools ?? []) { tool in Text(tool.name+" · "+doc.fmt(tool.diameter)).tag(Optional(tool.id)) }
                        if let toolID,doc.studio.setupProfile?.tools.contains(where: { $0.id == toolID }) != true { Text("Missing cutter").tag(Optional(toolID)) }
                    }
                    if let profile = doc.studio.setupProfile { Text(profile.name).font(.caption).foregroundStyle(.secondary) }
                    else { Text("Choose a CNC setup in Prepare CNC job to check cutter diameter and reach.").font(.caption).foregroundStyle(.secondary) }
                    if let project = report?.project {
                        ForEach(MachiningReview.issues(project:project).filter { $0.part == partID && $0.feature?.feature == initial.id && $0.severity >= .warning }) { issue in
                            Label(issue.message,systemImage:issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle").font(.caption).foregroundStyle(issue.severity == .error ? Color.red : .orange)
                        }
                    }
                }.padding(6)
            }
            Toggle("Feature enabled",isOn:$enabled)
            Text("One sketch creates one machining feature. Draw a new shape to replace this outline; add another sketch for another cut.").font(.caption2).foregroundStyle(.secondary)
            if case .failure(let issue) = generated { Label(issue.localizedDescription,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
            Text("Curve chord tolerance: "+Units.format(FaceSketch.tolerance,metric:doc.metric)+". Grooves export as closed pocket boundaries.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func dimension(_ field: SketchDimension) -> some View {
        let driven = sketch.expressions.contains { $0.field == field } || (sketch.concentricWith != nil && (field == .centerU || field == .centerV)) || (sketch.keepCircular == true && field == .height)
        HStack {
            if field.angle {
                AngleField(label:field.rawValue,value:Binding(get:{evaluated.value(field)},set:{ value in change { $0.set(field,value) } }),limit:field == .sweep ? 359.99 : 360)
            } else {
                DimField(label:field.rawValue,value:Binding(get:{evaluated.value(field)},set:{ value in change { $0.set(field,value) } }),metric:doc.metric,minimum:field == .centerU || field == .centerV ? -10000 : 0.0001)
            }
            if driven { Image(systemName:"link").foregroundStyle(.secondary).help("Driven by a parameter expression") }
        }.disabled(driven)
    }
    private var pathControls: some View {
        VStack(alignment:.leading,spacing:10) {
            Toggle("Closed path",isOn:Binding(get:{sketch.closed},set:{ value in change { $0.closed = value;if !value { $0.mode = .groove } } }))
            HStack { Text("\(sketch.nodes.count) points").font(.caption).foregroundStyle(.secondary);Spacer();if tool == .pen { Button("Finish path") { tool = .select } } }
            if let selected,sketch.nodes.indices.contains(selected) {
                Text("Point \(selected+1)").font(.headline)
                nodeCoordinate("U",axis:0,index:selected);nodeCoordinate("V",axis:1,index:selected)
                HStack {
                    Button("Curve") { curve(selected) }.disabled(selected == sketch.nodes.count-1 && !sketch.closed)
                    Button("Straight") { change { s in s.nodes[selected].outgoing = nil;if selected+1<s.nodes.count || s.closed { let next = (selected+1)%s.nodes.count;s.nodes[next].incoming = nil } } }
                    Button("Delete",role:.destructive) { change { $0.nodes.remove(at:selected) };self.selected = nil }
                }
                Button("Insert point on next edge") {
                    change { s in var profile = BoardProfile(u:0,v:1,nodes:s.nodes);profile.split(after:selected);s.nodes = profile.nodes }
                    self.selected = selected+1
                }.disabled(sketch.nodes.count>=64 || (selected == sketch.nodes.count-1 && !sketch.closed))
                DimField(label:"Corner size",value:$cornerRadius,metric:doc.metric,minimum:0.001)
                HStack {
                    Button("Fillet corner") { trimCorner(selected,chamfer:false) }
                    Button("Chamfer corner") { trimCorner(selected,chamfer:true) }
                }
                Text("Curve creates handles on the next segment. Drag the blue handles to shape it.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Select a point on the canvas to edit its position or curve handles.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var constraintControls: some View {
        GroupBox("Persistent constraints") {
            VStack(alignment:.leading,spacing:9) {
                ForEach(sketch.constraints ?? []) { constraint in
                    HStack { Text("Edge \(constraint.edge+1) · "+constraint.kind.rawValue).font(.caption);Spacer();Button { change { s in var list = s.constraints ?? [];list.removeAll { $0.id == constraint.id };s.constraints = list } } label: { Image(systemName:"xmark.circle") }.buttonStyle(.plain).help("Remove constraint") }
                }
                if let selected {
                    Text("Drive edge \(selected+1) → point \(selected+2)").font(.caption).foregroundStyle(.secondary)
                    Picker("Rule",selection:$constraintKind) { ForEach(SketchConstraintKind.allCases) { Text($0.rawValue).tag($0) } }
                    if [.parallel,.perpendicular,.equalLength].contains(constraintKind) { Picker("Reference edge",selection:$constraintReference) { ForEach(0..<max(1,selected),id:\.self) { Text("Edge \($0+1)").tag($0) } } }
                    if constraintKind == .length { DimField(label:"Length",value:$constraintLength,metric:doc.metric,minimum:0.001) }
                    Button("Add constraint") { change { s in
                        var list = s.constraints ?? []
                        let point = selected+1<s.nodes.count ? s.center+(s.nodes[selected+1].point-SIMD2(repeating:0.5))*s.size : nil
                        list.append(SketchConstraint(kind:constraintKind,edge:selected,reference:constraintReference,value:constraintLength,point:point));s.constraints = list
                    } }
                } else { Text("Select a path point to constrain its next edge. Reference edges must come earlier in the path.").font(.caption).foregroundStyle(.secondary) }
            }.padding(5)
        }
    }
    private func trimCorner(_ index: Int,chamfer: Bool) {
        do { let result = try SketchCorners.trim(sketch,index:index,radius:cornerRadius,chamfer:chamfer);change { $0 = result };selected = nil }
        catch { self.error = error.localizedDescription }
    }
    private func nodeCoordinate(_ label: String,axis: Int,index: Int) -> some View {
        DimField(label:label,value:Binding(get:{evaluated.facePoint(evaluated.nodes[index].point,faceSize:faceSize)[axis]},set:{ value in
            let frame = evaluated
            change { s in
                var p = frame.facePoint(s.nodes[index].point,faceSize:faceSize);p[axis] = value
                let normalized = frame.sketchPoint(p,faceSize:faceSize),delta = normalized-s.nodes[index].point
                s.nodes[index].point = normalized;s.nodes[index].incoming = s.nodes[index].incoming.map { $0+delta };s.nodes[index].outgoing = s.nodes[index].outgoing.map { $0+delta }
            }
        }),metric:doc.metric)
    }
    private var footer: some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:3) {
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                else if let report { Text("Preview ready · \(report.affected.count) part(s) regenerate").foregroundStyle(.secondary) }
                else { Text("Preview the result before applying it to the part.").foregroundStyle(.secondary) }
                if part?.component != nil { Text("This edit also updates shared component instances.").foregroundStyle(.secondary) }
            }.font(.caption).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Preview in 3D") { preview() }.disabled((try? generated.get()) == nil)
            Button("Apply sketch") {
                if let report,doc.applyDimensionPreview(report,historyTitle:"Face sketch · "+name) {
                    doc.selectFeature(FeatureRef(part:partID,kind:.operation,feature:initial.id));doc.status = "Saved editable face sketch. Double-click its machining to edit the curve.";dismiss()
                } else { error = doc.status }
            }.buttonStyle(.borderedProminent).disabled(report?.canApply != true)
        }.padding(16)
    }
    private func change(_ edit: (inout FaceSketch) -> Void) {
        var next = sketch;edit(&next)
        guard next != sketch else { return }
        undo.append(sketch);if undo.count>100 { undo.removeFirst() };redo = [];sketch = next
    }
    private func beginGesture() { if gestureBefore == nil { gestureBefore = sketch } }
    private func endGesture() {
        if let before = gestureBefore,before != sketch { undo.append(before);if undo.count>100 { undo.removeFirst() };redo = [] }
        gestureBefore = nil
    }
    private func invalidate() { report = nil;error = "";preview3D = false;doc.clearParameterPreview() }
    private func choose(_ next: FaceSketchTool) {
        preview3D = false;tool = next;selected = nil
        if next == .pen,sketch.shape != .path {
            change { s in s.shape = .path;s.nodes = [];s.closed = false;s.mode = .groove;s.orientation = SketchOrientation();s.center = faceSize/2;s.size = faceSize;s.referenceFaceSize = faceSize;s.expressions = [];s.constraints = nil;s.islandInset = nil;s.keepCircular = nil;s.concentricWith = nil }
        }
    }
    private func curve(_ index: Int) {
        let next = index+1<sketch.nodes.count ? index+1 : (sketch.closed ? 0 : index)
        guard next != index else { return }
        change { s in
            let a = s.nodes[index].point,b = s.nodes[next].point,delta = b-a,normal = SIMD2(-delta.y,delta.x)/4
            s.nodes[index].outgoing = a+delta/3+normal;s.nodes[next].incoming = b-delta/3+normal
        }
    }
    private func preview() {
        guard let baseline,baseline == doc.project else { error = "The design changed while this editor was open. Close and reopen the sketch to refresh it.";return }
        do {
            var operation = initial;operation.name = name;operation.suppressed = !enabled
            guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ModelValidation.Failure(message:"Give the sketch a name for its feature history.") }
            let value = try FaceSketchEditing.preview(baseline,partID:partID,operation:operation,values:sketch,toolID:toolID,replaceToolAssignment:true)
            report = value;doc.parameterPreview = value.project;doc.previewAffected = Set(value.affected);preview3D = true;error = ""
        } catch { doc.clearParameterPreview();report = nil;self.error = error.localizedDescription }
    }
}

struct SketchResultPreview: NSViewRepresentable {
    let part: Part
    let axis: Int
    let positive: Bool
    final class Coordinator { var last: Part? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView();view.allowsCameraControl = true;view.autoenablesDefaultLighting = true;view.antialiasingMode = .multisampling4X
        return view
    }
    func updateNSView(_ view: SCNView,context: Context) {
        guard context.coordinator.last != part else { return };context.coordinator.last = part
        let scene = SCNScene();scene.background.contents = NSColor.windowBackgroundColor
        let node = SCNNode(geometry:Geo.geometry(for:part,polygons:Geo.polys(for:part)));node.position = vec(-part.size/2);scene.rootNode.addChildNode(node)
        let camera = SCNNode();camera.camera = SCNCamera();camera.camera?.automaticallyAdjustsZRange = true;camera.camera?.fieldOfView = 35
        let radius = max(2,norm(part.size));var direction = SIMD3<Double>(repeating:0.7);direction[axis] = positive ? 1.5 : -1.5
        camera.position = vec(direction*radius);camera.look(at:SCNVector3Zero);scene.rootNode.addChildNode(camera)
        view.scene = scene;view.pointOfView = camera
    }
}
