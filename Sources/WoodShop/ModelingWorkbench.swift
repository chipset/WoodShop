import SwiftUI
import simd

struct AssemblyWorkbench: View {
    @ObservedObject var doc: Document
    @State private var axis = 1
    @State private var pivot = SIMD3<Double>.zero
    @State private var angle = 90.0
    @State private var copies = 4
    @State private var step = SIMD3<Double>(4, 0, 0)
    @State private var scale = SIMD3<Double>(repeating: 1)
    @State private var mirrorCopy = true
    @State private var assembly = "Cabinet/Carcass"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Components & nested assemblies") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Make linked component(s)") { doc.makeComponents() }
                            Button("Make unique") { doc.makeComponents(unique: true) }
                        }.disabled(doc.selectedIDs.isEmpty)
                        Text("Copies of a component share size, shape, material, and machining. Placement is independent. Make Unique detaches an instance before editing.").font(.caption)
                        HStack {
                            TextField("Assembly path", text: $assembly)
                            Button("Assign assembly") { doc.setGroup(assembly) }.disabled(doc.selectedIDs.isEmpty)
                            Button("Select assembly tree") { doc.selectAssembly(assembly) }
                        }
                        Text("Use paths such as Cabinet/Carcass/Left. Selecting Cabinet includes every nested assembly.").font(.caption)
                    }.padding(8)
                }
                VectorFields(title: "World pivot / mirror plane point", value: $pivot, metric: doc.metric)
                Button("Use selection center") {
                    let bounds = doc.parts.filter { doc.selectedIDs.contains($0.id) }.map(\.bounds)
                    if let first = bounds.first {
                        let lo = bounds.reduce(first.lo) { pointwiseMin($0, $1.lo) }, hi = bounds.reduce(first.hi) { pointwiseMax($0, $1.hi) }
                        pivot = (lo + hi) / 2
                    }
                }
                AxisPicker(title: "Axis", value: $axis)
                GroupBox("Rotate & copy") {
                    HStack {
                        AngleField(label: "Angle", value: $angle)
                        Stepper("Copies: \(copies)", value: $copies, in: 1...100)
                        Button("Rotate") { doc.rotateAround(axis: axis, degrees: angle, pivot: pivot) }
                        Button("Circular array") { doc.rotateAround(axis: axis, degrees: angle, pivot: pivot, copies: copies) }
                    }.padding(8)
                }
                VectorFields(title: "Linear array spacing", value: $step, metric: doc.metric)
                Button("Create \(copies) linear copies") { doc.linearArray(count: copies, step: step) }
                GroupBox("Mirror") {
                    HStack {
                        Toggle("Keep original", isOn: $mirrorCopy)
                        Button("Mirror across selected axis plane") { doc.mirrorSelection(axis: axis, plane: pivot[axis], copy: mirrorCopy) }
                    }.padding(8)
                }
                GroupBox("Scale") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { ForEach(0..<3) { a in TextField(FaceRef.axisNames[a], value: Binding(get: { scale[a] }, set: { scale[a] = $0 }), format: .number).textFieldStyle(.roundedBorder) } }
                        Button("Scale about pivot") { doc.scaleSelection(scale, pivot: pivot) }
                        Text("Mirroring preserves machining features in an independent part. World scaling bakes an independent solid and removes affected dimension links.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }.padding(12)
        }
    }
}
struct DrawingWorkbench: View {
    @ObservedObject var doc: Document
    @State private var shape = "Polygon"
    @State private var sides = 6
    @State private var width = 12.0
    @State private var height = 8.0
    @State private var thickness = 0.75
    @State private var arcAngle = 180.0
    @State private var offset = 0.25
    @State private var extrusion = 1.0
    @State private var roundSweep = false
    @State private var profileWidth = 0.75
    @State private var profileHeight = 1.5
    @State private var pathText = "0,0,0\n12,0,0\n12,0,12"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Create a face / solid") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Shape", selection: $shape) { ForEach(["Polygon", "Circle / ellipse", "Arc sector", "Rectangle"], id: \.self) { Text($0) } }
                        Stepper("Polygon sides: \(sides)", value: $sides, in: 3...64)
                        HStack {
                            DimField(label: "Width", value: $width, metric: doc.metric, minimum: 1 / 32)
                            DimField(label: "Height", value: $height, metric: doc.metric, minimum: 1 / 32)
                            DimField(label: "Thickness", value: $thickness, metric: doc.metric, minimum: 1 / 32)
                        }
                        if shape == "Arc sector" { AngleField(label: "Arc sweep", value: $arcAngle, limit: 359.9) }
                        Button("Create shape") { createShape() }
                        Text("For a custom line-and-curve face, create a board and open Edit curves. Its sketch canvas supports drawing connected edges and editing Bézier handles.").font(.caption)
                    }.padding(8)
                }
                GroupBox("Edit selected geometry") {
                    HStack {
                        DimField(label: "Offset", value: $offset, metric: doc.metric)
                        Button("Offset outline") { doc.offsetProfile(offset) }.disabled(doc.selectedPart == nil)
                        DimField(label: "Face distance", value: $extrusion, metric: doc.metric)
                        Button("Extrude selected face") { doc.extrudeSurface(amount: extrusion) }.disabled(doc.selectedSurface == nil)
                    }.padding(8)
                }
                GroupBox("Follow a path / molding sweep") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Round profile", isOn: $roundSweep)
                        HStack {
                            DimField(label: "Profile width", value: $profileWidth, metric: doc.metric, minimum: 1 / 32)
                            DimField(label: "Profile height", value: $profileHeight, metric: doc.metric, minimum: 1 / 32)
                        }
                        Text("Path points: X,Y,Z per line. Bare values use the current unit system; explicit units such as 12in or 300mm are accepted.").font(.caption)
                        TextEditor(text: $pathText).font(.system(.body, design: .monospaced)).frame(height: 120).border(Color.secondary.opacity(0.3))
                        Button("Create swept solid") {
                            do {
                                let path = try GeometryImport.points3D(pathText, metric: doc.metric)
                                let profile = roundSweep ? MeshTools.circle(center: .zero, radius: profileWidth / 2) : [SIMD2(-profileWidth / 2, -profileHeight / 2), SIMD2(profileWidth / 2, -profileHeight / 2), SIMD2(profileWidth / 2, profileHeight / 2), SIMD2(-profileWidth / 2, profileHeight / 2)]
                                let polys = try MeshTools.sweep(profile: profile, path: path)
                                doc.add(try MeshTools.part(polygons: polys, name: doc.nextName("Sweep"), species: doc.species))
                            } catch { doc.status = error.localizedDescription }
                        }
                    }.padding(8)
                }
            }.padding(12)
        }
    }
    private func createShape() {
        var p = Part(name: doc.nextName(shape), origin: .zero, size: SIMD3(width, thickness, height), species: doc.species)
        p.thicknessAxis = 1; p.grainDirection = 0
        var points: [SIMD2<Double>]
        switch shape {
        case "Circle / ellipse": p.profile = .preset(.oval, part: p); doc.add(p); return
        case "Arc sector":
            guard arcAngle > 0, arcAngle < 360 else { doc.status = "Arc sweep must be between 0° and 360°."; return }
            let n = max(1, Int(ceil(arcAngle / 90)))
            var nodes: [BoardProfile.Node] = [.init(point: SIMD2(0.5,0.5)), .init(point: SIMD2(1,0.5))]
            for i in 0..<n {
                let a = arcAngle * Double(i) / Double(n) * .pi / 180, b = arcAngle * Double(i + 1) / Double(n) * .pi / 180
                let k = 4 / 3.0 * tan((b - a) / 4), end = SIMD2(0.5 + 0.5 * cos(b),0.5 + 0.5 * sin(b))
                nodes[nodes.count - 1].outgoing = nodes.last!.point + 0.5 * k * SIMD2(-sin(a),cos(a))
                nodes.append(.init(point: end, incoming: end - 0.5 * k * SIMD2(-sin(b),cos(b))))
            }
            p.profile = BoardProfile(u:0,v:2,nodes:nodes); doc.add(p); return
        case "Rectangle": points = [.zero, SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        default: points = MeshTools.circle(center: SIMD2(0.5, 0.5), radius: 0.5, segments: sides)
        }
        p.profile = BoardProfile(u: 0, v: 2, nodes: points.map { .init(point: $0) })
        doc.add(p)
    }
}
struct DocumentationWorkbench: View {
    @ObservedObject var doc: Document
    let ctrl: SceneController
    @State private var guidePoint = SIMD3<Double>.zero
    @State private var guideAxis = 0
    @State private var sceneName = "Assembly"
    @State private var dimensionName = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Construction guides") {
                    VStack(alignment: .leading, spacing: 8) {
                        VectorFields(title: "Guide point", value: $guidePoint, metric: doc.metric)
                        AxisPicker(title: "Direction", value: $guideAxis)
                        Button("Add guide") {
                            var direction = SIMD3<Double>.zero; direction[guideAxis] = 1
                            doc.transaction { doc.studio.guides.append(ConstructionGuide(point: guidePoint, direction: direction)) }
                        }
                        ForEach(doc.studio.guides) { guide in
                            HStack {
                                Text("Through \(doc.fmt(guide.point.x)), \(doc.fmt(guide.point.y)), \(doc.fmt(guide.point.z))")
                                Spacer()
                                Button("Remove") { doc.transaction { doc.studio.guides.removeAll { $0.id == guide.id } } }
                            }
                        }
                    }.padding(8)
                }
                AssemblyStepsEditor(doc:doc).frame(minHeight:260)
                GroupBox("Persistent dimensions") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pick two points using Tape Measure, then keep the measurement here. Dimensions use fixed world points and are saved in the project and shop drawings.").font(.caption)
                        HStack { TextField("Label (optional)", text: $dimensionName); Button("Keep last measurement") { doc.rememberMeasurement(name: dimensionName) } }
                        ForEach(doc.studio.dimensions) { dimension in
                            HStack {
                                Text("\(dimension.name) \(doc.fmt(norm(dimension.b - dimension.a)))")
                                Spacer()
                                Button("Remove") { doc.transaction { doc.studio.dimensions.removeAll { $0.id == dimension.id } } }
                            }
                        }
                    }.padding(8)
                }
                GroupBox("Section view") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable section", isOn: Binding(get: { doc.studio.section != nil }, set: { v in doc.transaction { doc.studio.section = v ? SectionPlane() : nil } }))
                        if let section = doc.studio.section {
                            AxisPicker(title: "Normal", value: Binding(get: { section.axis }, set: { v in doc.transaction { doc.studio.section?.axis = v } }))
                            DimField(label: "Plane position", value: Binding(get: { section.value }, set: { v in doc.transaction { doc.studio.section?.value = v } }), metric: doc.metric)
                            Toggle("Keep positive side", isOn: Binding(get: { section.keepPositive }, set: { v in doc.transaction { doc.studio.section?.keepPositive = v } }))
                        }
                        Text("Sections affect the viewport; fabrication exports retain the complete solid.").font(.caption)
                    }.padding(8)
                }
                GroupBox("Saved scenes") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField("Scene name", text: $sceneName); Button("Save current view") { ctrl.saveScene(sceneName) } }
                        ForEach(doc.studio.scenes) { scene in
                            HStack {
                                Button(scene.name) { ctrl.restoreScene(scene) }
                                Spacer()
                                Button("Remove") { doc.transaction { doc.studio.scenes.removeAll { $0.id == scene.id } } }
                            }
                        }
                    }.padding(8)
                }
            }.padding(12)
        }
    }
}
struct LibraryWorkbench: View {
    @ObservedObject var doc: Document
    @State private var name = "My component"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Import geometry") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Import 3D model or outline…") { doc.importGeometry() }
                        Text("SVG and DXF closed contours become extruded profiles. OBJ becomes an editable solid mesh. SVG supports paths, polygons, rectangles, ellipses, and transforms; DXF supports polylines and circles. Unsupported entities are reported.").font(.caption)
                    }.padding(8)
                }
                GroupBox("Hardware reference library") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { ForEach(["Dowel", "Hinge", "Drawer slide"], id: \.self) { kind in Button(kind) { doc.addHardware(kind) } } }
                        Text("Hinges and slides are adjustable reference envelopes, not manufacturer-certified models. Hardware is excluded from lumber cut lists and CNC nesting.").font(.caption)
                    }.padding(8)
                }
                GroupBox("Project library") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField("Library item name", text: $name); Button("Save selection") { doc.saveLibraryItem(name: name) }.disabled(doc.selectedIDs.isEmpty) }
                        ForEach(doc.studio.library) { item in
                            HStack {
                                Text("\(item.name) (\(item.parts.count) parts)")
                                Spacer()
                                Button("Insert") { doc.insertLibrary(item) }
                                Button("Remove") { doc.transaction { doc.studio.library.removeAll { $0.id == item.id } } }
                            }
                        }
                    }.padding(8)
                }
                GroupBox("Existing component definitions") {
                    VStack(alignment: .leading) {
                        let representatives = Dictionary(grouping: doc.parts.filter { $0.component != nil }, by: { $0.component! }).values.compactMap(\.first)
                        ForEach(representatives.sorted { $0.name < $1.name }) { p in
                            Button("Insert linked copy of \(p.name)") { doc.select(p.id); doc.duplicateSelected() }
                        }
                    }.padding(8)
                }
            }.padding(12)
        }
    }
}
