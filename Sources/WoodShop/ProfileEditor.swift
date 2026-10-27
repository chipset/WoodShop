import SwiftUI
import AppKit

struct ProfileSection: View {
    @ObservedObject var doc: Document
    let part: Part
    @State private var editing = false

    var body: some View {
        GroupBox("Board shape") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Menu("Choose shape") {
                        Button("Rectangle") { doc.edit(part.id) { $0.profile = nil } }
                        ForEach(BoardProfile.Preset.allCases) { preset in
                            Button(preset.rawValue) {
                                doc.edit(part.id) { $0.profile = .preset(preset, part: $0) }
                            }
                        }
                    }
                    Button("Edit curves…") { editing = true }
                }
                if let profile = part.profile {
                    ProfilePreview(profile: profile, size: part.size).frame(height: 105)
                    Text("Outline on \(FaceRef.axisNames[profile.u]) × \(FaceRef.axisNames[profile.v]); depth along \(FaceRef.axisNames[profile.thickness]).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Choose a curved shape or draw your own outline.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
        .sheet(isPresented: $editing) { ProfileEditor(doc: doc, part: part) }
    }
}

private struct ProfileLayout {
    var rect: CGRect
    init(size: CGSize, board: SIMD3<Double>, profile: BoardProfile) {
        let available = CGRect(origin: .zero, size: size).insetBy(dx: 26, dy: 26)
        let scale = min(available.width / board[profile.u], available.height / board[profile.v])
        let w = board[profile.u] * scale, h = board[profile.v] * scale
        rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
    func map(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.maxY - p.y * rect.height) }
    func unmap(_ p: CGPoint) -> SIMD2<Double> {
        SIMD2(max(0, min(1, (p.x - rect.minX) / rect.width)), max(0, min(1, (rect.maxY - p.y) / rect.height)))
    }
    func path(_ profile: BoardProfile) -> Path {
        Path { path in
            guard let first = profile.nodes.first else { return }
            path.move(to: map(first.point))
            for i in profile.nodes.indices {
                let a = profile.nodes[i], b = profile.nodes[(i + 1) % profile.nodes.count]
                if a.outgoing == nil && b.incoming == nil { path.addLine(to: map(b.point)) }
                else { path.addCurve(to: map(b.point), control1: map(a.outgoing ?? a.point), control2: map(b.incoming ?? b.point)) }
            }
            path.closeSubpath()
        }
    }
}

struct ProfilePreview: View {
    let profile: BoardProfile
    let size: SIMD3<Double>
    var body: some View {
        GeometryReader { geometry in
            let layout = ProfileLayout(size: geometry.size, board: size, profile: profile)
            layout.path(profile).fill(Color.brown.opacity(0.25))
                .overlay(layout.path(profile).stroke(Color.primary, lineWidth: 1.5))
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ProfileEditor: View {
    @ObservedObject var doc: Document
    let part: Part
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BoardProfile
    @State private var selected = 0
    @State private var drawing = false
    @State private var drawn: [SIMD2<Double>] = []

    init(doc: Document, part: Part) {
        self.doc = doc; self.part = part
        let axes = part.materialAxes
        _draft = State(initialValue: part.profile ?? BoardProfile(u: axes.l, v: axes.w, nodes: [
            .init(point: SIMD2(0, 0)), .init(point: SIMD2(1, 0)), .init(point: SIMD2(1, 1)), .init(point: SIMD2(0, 1))
        ]))
    }

    private var error: String? {
        var candidate = part; candidate.profile = draft
        return ModelValidation.part(candidate)
    }
    private var next: Int { (selected + 1) % draft.nodes.count }
    private var curved: Bool { draft.nodes[selected].outgoing != nil || draft.nodes[next].incoming != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit outline — \(part.name)").font(.title2)
            Text("Drag points to shape the board. Select a point and drag its blue handles to bend the edges.")
                .foregroundStyle(.secondary)
            HStack {
                Menu("Start from shape") {
                    ForEach(BoardProfile.Preset.allCases) { preset in
                        Button(preset.rawValue) {
                            var p = part; p.thicknessAxis = draft.thickness; p.grainDirection = draft.u
                            draft = .preset(preset, part: p); selected = 0
                        }
                    }
                }
                Picker("Depth axis", selection: Binding(get: { draft.thickness }, set: { axis in
                    let remaining = (0..<3).filter { $0 != axis }
                    draft.u = remaining.max { part.size[$0] < part.size[$1] }!
                    draft.v = remaining.first { $0 != draft.u }!
                })) { ForEach(0..<3) { Text(FaceRef.axisNames[$0]).tag($0) } }
                .frame(width: 155)
                Toggle("Draw lines", isOn: $drawing).toggleStyle(.button)
                    .onChange(of: drawing) { _, value in if value { drawn = [] } }
                if drawing {
                    Button("Close face") { closeDrawing() }.disabled(drawn.count < 3)
                    Button("Undo point") { if !drawn.isEmpty { drawn.removeLast() } }
                }
                Spacer()
                Text("\(doc.fmt(part.size[draft.u])) × \(doc.fmt(part.size[draft.v]))").monospacedDigit()
            }
            HStack(alignment: .top, spacing: 18) {
                canvas.frame(width: 550, height: 390)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Point \(selected + 1) of \(draft.nodes.count)").font(.headline)
                    DimField(label: FaceRef.axisNames[draft.u], value: position(0), metric: doc.metric)
                    DimField(label: FaceRef.axisNames[draft.v], value: position(1), metric: doc.metric)
                    Button("Arc next edge") {
                        let a = draft.nodes[selected].point, b = draft.nodes[next].point, d = b - a
                        let k = 2 / 3.0 * tan(Double.pi / 8), bend = SIMD2(-d.y, d.x) * k
                        draft.nodes[selected].outgoing = a + d * k + bend
                        draft.nodes[next].incoming = b - d * k + bend
                    }
                    Toggle("Curve next edge", isOn: Binding(get: { curved }, set: { enabled in
                        let a = draft.nodes[selected].point, b = draft.nodes[next].point
                        draft.nodes[selected].outgoing = enabled ? a + (b - a) / 3 : nil
                        draft.nodes[next].incoming = enabled ? a + (b - a) * 2 / 3 : nil
                    }))
                    Button("Add point on next edge") { draft.split(after: selected); selected += 1 }
                        .disabled(draft.nodes.count >= 64)
                    Button("Remove point") {
                        draft.nodes.remove(at: selected); selected = min(selected, draft.nodes.count - 1)
                    }.disabled(draft.nodes.count <= 3)
                    Divider()
                    Text("The outline stays inside the blank and scales when you resize the board. Choose a different depth axis to shape a side or end.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.frame(width: 220)
            }
            HStack {
                Text(error ?? "Ready to apply. You can undo the whole shape change.")
                    .font(.callout).foregroundStyle(error == nil ? Color.secondary : Color.red)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply shape") {
                    doc.edit(part.id) { $0.profile = draft }
                    doc.selectedFace = nil
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(error != nil)
            }
        }.padding(22).frame(width: 850).background(Color(nsColor: .windowBackgroundColor))
    }

    private func position(_ coordinate: Int) -> Binding<Double> {
        let axis = coordinate == 0 ? draft.u : draft.v
        return Binding(get: { draft.nodes[selected].point[coordinate] * part.size[axis] }, set: { value in
            var point = draft.nodes[selected].point
            point[coordinate] = max(0, min(1, value / part.size[axis]))
            movePoint(selected, to: point)
        })
    }

    private func movePoint(_ index: Int, to point: SIMD2<Double>) {
        let node = draft.nodes[index]
        var delta = point - node.point
        for p in [node.point, node.incoming, node.outgoing].compactMap({ $0 }) {
            for axis in 0..<2 { delta[axis] = max(-p[axis], min(1 - p[axis], delta[axis])) }
        }
        draft.nodes[index].point += delta
        draft.nodes[index].incoming = node.incoming.map { $0 + delta }
        draft.nodes[index].outgoing = node.outgoing.map { $0 + delta }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let layout = ProfileLayout(size: geometry.size, board: part.size, profile: draft)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor))
                Path { $0.addRect(layout.rect) }.stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                layout.path(draft).fill(Color.brown.opacity(0.2))
                layout.path(draft).stroke(error == nil ? Color.primary : Color.red, lineWidth: 2)
                if drawing {
                    Path { path in
                        if let first = drawn.first { path.move(to: layout.map(first)); for p in drawn.dropFirst() { path.addLine(to: layout.map(p)) } }
                    }.stroke(Color.accentColor, lineWidth: 2)
                    ForEach(drawn.indices, id: \.self) { i in Circle().fill(Color.accentColor).frame(width: 7, height: 7).position(layout.map(drawn[i])) }
                }
                // Show both handles of the selected edge, and the selected point's incoming handle.
                handle(selected, incoming: true, layout: layout)
                handle(selected, incoming: false, layout: layout)
                handle(next, incoming: true, layout: layout)
                ForEach(draft.nodes.indices, id: \.self) { i in
                    Circle().fill(i == selected ? Color.accentColor : Color.white)
                        .overlay(Circle().stroke(Color.primary, lineWidth: 1.5))
                        .frame(width: 12, height: 12).contentShape(Circle().size(width: 20, height: 20))
                        .position(layout.map(draft.nodes[i].point))
                        .onTapGesture { selected = i }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("outline"))
                            .onChanged { value in selected = i; movePoint(i, to: layout.unmap(value.location)) })
                        .allowsHitTesting(!drawing)
                        .accessibilityLabel("Outline point \(i + 1)")
                }
            }.coordinateSpace(name: "outline")
            .simultaneousGesture(SpatialTapGesture().onEnded { event in
                guard drawing, drawn.count < 64 else { return }
                var point = layout.unmap(event.location)
                let candidates = draft.nodes.map(\.point) + draft.nodes.indices.map { (draft.nodes[$0].point + draft.nodes[($0 + 1) % draft.nodes.count].point) / 2 } + drawn
                if let nearest = candidates.min(by: { a, b in
                    hypot(layout.map(a).x - event.location.x, layout.map(a).y - event.location.y) < hypot(layout.map(b).x - event.location.x, layout.map(b).y - event.location.y)
                }), hypot(layout.map(nearest).x - event.location.x, layout.map(nearest).y - event.location.y) <= 9 { point = nearest }
                else {
                    point.x = min(1, max(0, (point.x * part.size[draft.u] / doc.snap).rounded() * doc.snap / part.size[draft.u]))
                    point.y = min(1, max(0, (point.y * part.size[draft.v] / doc.snap).rounded() * doc.snap / part.size[draft.v]))
                }
                if NSEvent.modifierFlags.contains(.shift), let last = drawn.last {
                    if abs(point.x - last.x) > abs(point.y - last.y) { point.y = last.y } else { point.x = last.x }
                }
                if drawn.count >= 3, let first = drawn.first, hypot(layout.map(first).x - event.location.x, layout.map(first).y - event.location.y) <= 9 { closeDrawing() }
                else if drawn.last != point { drawn.append(point) }
            })
        }
    }

    private func closeDrawing() {
        guard drawn.count >= 3 else { return }
        draft.nodes = drawn.map { .init(point: $0) }; selected = 0; drawing = false
    }

    @ViewBuilder private func handle(_ index: Int, incoming: Bool, layout: ProfileLayout) -> some View {
        let node = draft.nodes[index]
        if let point = incoming ? node.incoming : node.outgoing {
            Path { path in path.move(to: layout.map(node.point)); path.addLine(to: layout.map(point)) }
                .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                .position(layout.map(point))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("outline"))
                    .onChanged { value in
                        if incoming { draft.nodes[index].incoming = layout.unmap(value.location) }
                        else { draft.nodes[index].outgoing = layout.unmap(value.location) }
                    })
                .accessibilityLabel(incoming ? "Incoming curve handle" : "Outgoing curve handle")
        }
    }
}
