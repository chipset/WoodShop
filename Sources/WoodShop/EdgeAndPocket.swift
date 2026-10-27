import SwiftUI

/// Pocket holes and chamfer/roundover edge profiles for the selected face.
struct EdgeAndPocketSection: View {
    @ObservedObject var doc: Document
    let part: Part
    let face: FaceRef

    enum Mode: String, CaseIterable, Identifiable {
        case pocket = "Pocket Hole", edge = "Edge Profile"
        var id: String { rawValue }
    }
    enum EdgeKind: String, CaseIterable { case chamfer = "Chamfer", roundover = "Roundover" }

    @State private var mode = Mode.pocket
    @State private var runOnV = true
    @State private var pocketToPositive = true
    @State private var pocketFromEnd = 1.5
    @State private var pocketAcross = 1.0
    @State private var pocketDiameter = 0.375
    @State private var pocketAngle = 15.0
    @State private var pocketLength = 1.5
    @State private var edgeKind = EdgeKind.roundover
    @State private var neighbor = 0
    @State private var edgeSize = 0.25

    private var u: Int { (face.axis + 1) % 3 }
    private var v: Int { (face.axis + 2) % 3 }
    private var run: Int { runOnV ? v : u }
    private func name(_ axis: Int) -> String { FaceRef.axisNames[axis] }
    private var neighbors: [FaceRef] {
        [u, v].flatMap { ax in [true, false].map { FaceRef(part: part.id, axis: ax, positive: $0) } }
    }

    var body: some View {
        GroupBox("Pocket holes & edge profiles (face \(face.label))") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Operation", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if mode == .pocket { pocket } else { edge }
                ExistingEdges(doc: doc, part: part)
            }.padding(4)
        }
        .onAppear { pocketAcross = part.size[v] / 2 }
    }

    private var pocket: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Run along", selection: $runOnV) { Text(name(v)).tag(true); Text(name(u)).tag(false) }.pickerStyle(.segmented)
            Toggle("Exit toward the + end", isOn: $pocketToPositive)
            DimField(label: "From end", value: $pocketFromEnd, metric: doc.metric, minimum: 0)
            DimField(label: "Across pos.", value: $pocketAcross, metric: doc.metric)
            DimField(label: "Bore", value: $pocketDiameter, metric: doc.metric, minimum: 1 / 64)
            AngleField(label: "Angle", value: $pocketAngle, limit: 60)
            DimField(label: "Length", value: $pocketLength, metric: doc.metric, minimum: 0.25)
            Text("A shallow-angle bore from this face toward the end, for a pocket-hole screw.").font(.caption).foregroundStyle(.secondary)
            Button("Add Pocket Hole") {
                let r = run
                let entryRun = pocketToPositive ? part.size[r] - pocketFromEnd : pocketFromEnd
                let cut = JoineryGen.pocketHole(part: part, face: face, run: r, towardPositiveEnd: pocketToPositive,
                                                entry: SIMD2(entryRun, pocketAcross), diameter: pocketDiameter,
                                                angle: pocketAngle, length: pocketLength)
                doc.edit(part.id) { $0.cuts.append(cut) }
                doc.status = "Pocket hole added."
            }
        }
    }

    private var edge: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Profile", selection: $edgeKind) { ForEach(EdgeKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Picker("Edge shared with", selection: $neighbor) {
                ForEach(neighbors.indices, id: \.self) { Text(neighbors[$0].label).tag($0) }
            }
            DimField(label: edgeKind == .chamfer ? "Leg" : "Radius", value: $edgeSize, metric: doc.metric, minimum: 1 / 64)
            Text("The profile runs the full length of the edge. A radius of half the board's width or thickness rounds the whole edge.").font(.caption).foregroundStyle(.secondary)
            Button("Add \(edgeKind.rawValue)") {
                let n = neighbors[min(neighbor, neighbors.count - 1)]
                let e = EdgeProfile(kind: edgeKind == .chamfer ? .chamfer : .roundover, axis1: face.axis, pos1: face.positive,
                                    axis2: n.axis, pos2: n.positive, size: edgeSize)
                doc.edit(part.id) { $0.edges = ($0.edges ?? []) + [e] }
                doc.status = "\(edgeKind.rawValue) added."
            }
        }
    }
}

struct ExistingEdges: View {
    @ObservedObject var doc: Document
    let part: Part
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(part.edges ?? []) { e in
                HStack {
                    Text("\(e.kind.rawValue.capitalized) \(doc.fmt(e.size)) on \(FaceRef(part: part.id, axis: e.axis1, positive: e.pos1).label)\(e.kind == .arch ? "" : " / " + FaceRef(part: part.id, axis: e.axis2, positive: e.pos2).label)")
                        .font(.caption)
                    Spacer()
                    Button { doc.edit(part.id) { $0.edges?.removeAll { $0.id == e.id }; if $0.edges?.isEmpty == true { $0.edges = nil } } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}
