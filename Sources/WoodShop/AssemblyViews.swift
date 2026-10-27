import SwiftUI
import AppKit

/// Keep the browser's sorting and assembly tree stable while selection and status change.
private final class PartBrowserIndex {
    private var revision: UInt64 = .max
    private var search = ""
    private var filter = ""
    private var parts: [Part] = []
    private var tree: [PartTreeNode] = []

    func filtered(_ doc: Document) -> [Part] {
        if revision != doc.partsRevision || search != doc.partSearch || filter != doc.partFilter {
            revision = doc.partsRevision; search = doc.partSearch; filter = doc.partFilter
            parts = doc.parts.filter { part in
                (filter == "All" || (filter == "Hardware" ? part.hardware == true : part.hardware != true)) &&
                PartSearch.matches(search,part:part)
            }
            tree = PartTreeNode.make(parts)
        }
        return parts
    }

    func assemblyTree(_ doc: Document) -> [PartTreeNode] {
        _ = filtered(doc)
        return tree
    }
}

struct PartsSidebar: View {
    @ObservedObject var doc: Document
    var ctrl: SceneController? = nil
    private var search: String { doc.partSearch }
    private var filter: String { doc.partFilter }
    @State private var expanded: Set<String> = []
    @FocusState private var searchFocused: Bool
    @State private var searchCandidate: UUID?
    @State private var index = PartBrowserIndex()
    private var filtered: [Part] {
        index.filtered(doc)
    }
    var body: some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:12) {
                HStack { Text("Parts").font(.headline);Text("\(doc.parts.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary);Spacer();Menu { Button("Show all parts") { doc.showAllParts() };Button("Select all visible") { WorkspaceAction.selectAll.run(doc:doc,ctrl:ctrl) } } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Parts browser options") }
                HStack(spacing:6) {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a part or assembly",text:$doc.partSearch).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Find a part or assembly")
                        .onSubmit { if let part = filtered.first(where: { $0.id == searchCandidate }) ?? filtered.first { doc.select(part.id);ctrl?.zoomSelection();searchFocused = false } }
                        .onKeyPress(.upArrow) { moveSearch(-1);return .handled }
                        .onKeyPress(.downArrow) { moveSearch(1);return .handled }
                        .onExitCommand { if search.isEmpty { searchFocused = false } else { doc.partSearch = "" } }
                        .help("Find by name, part ID, material, or assembly · ⌘F")
                    if !search.isEmpty { Button { doc.partSearch = "" } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear parts search") }
                }.padding(8).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                Picker("Show",selection:$doc.partFilter) { ForEach(["All","Parts","Hardware"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            }.padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:3) {
                        if search.isEmpty {
                            ForEach(index.assemblyTree(doc)) { node in
                                AssemblyTreeRow(doc:doc,ctrl:ctrl,node:node,expanded:$expanded)
                            }
                        } else { ForEach(filtered) { partRow($0) } }
                        if filtered.isEmpty { VStack(alignment:.leading,spacing:8) { Text(doc.parts.isEmpty ? "Your parts appear here" : "No matching parts").font(.headline);Text(doc.parts.isEmpty ? "Add stock or open a project to get started." : "Try a name, part ID, material, or assembly.").font(.callout).foregroundStyle(.secondary) }.padding(12) }
                    }.padding(10)
                }
                .onChange(of:doc.selection) { _,id in
                    revealSelection()
                    if let id { DispatchQueue.main.async { withAnimation { proxy.scrollTo(id,anchor:.center) } } }
                }
                .onAppear { revealSelection() }
                .onChange(of:searchCandidate) { _,id in if let id { proxy.scrollTo(id,anchor:.center) } }
            }
            Divider()
            HStack(spacing:10) {
                Text(doc.selectedIDs.isEmpty ? "\(filtered.count) parts" : "\(doc.selectedIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if doc.isolateSelection { Button("End isolation") { doc.isolateSelection = false }.font(.caption) }
                else { Button { doc.isolateSelection = true } label: { Image(systemName:"viewfinder") }.buttonStyle(.plain).disabled(doc.selectedIDs.isEmpty).help("Isolate selection") }
                Button { doc.showAllParts() } label: { Image(systemName:"eye") }.buttonStyle(.plain).help("Show all parts")
            }.padding(12)
        }.background(Color(nsColor:.windowBackgroundColor))
        .onChange(of:doc.focusPartSearch) { _,_ in searchFocused = true }
        .onChange(of:search) { _,_ in searchCandidate = filtered.first?.id }
        .onChange(of:filter) { _,_ in searchCandidate = filtered.first?.id }
    }
    private func revealSelection() {
        guard let part = doc.selectedPart else { return }
        let segments = (part.group ?? "").split(separator:"/")
        for count in 1...max(1,segments.count) where count <= segments.count { expanded.insert(segments.prefix(count).joined(separator:"/")) }
        if !PartSearch.matches(search,part:part) { doc.partSearch = "" }
        if filter == "Hardware" && part.hardware != true || filter == "Parts" && part.hardware == true { doc.partFilter = "All" }
    }
    private func moveSearch(_ step: Int) {
        guard !search.isEmpty,!filtered.isEmpty else { return }
        let index = filtered.firstIndex { $0.id == searchCandidate } ?? (step > 0 ? -1 : 0)
        searchCandidate = filtered[max(0,min(filtered.count-1,index+step))].id
    }
    private func partRow(_ part: Part) -> some View { PartBrowserRow(doc:doc,ctrl:ctrl,part:part,searchCandidate:searchFocused && !search.isEmpty && searchCandidate == part.id) }
}

struct AssemblyTreeRow: View {
    @ObservedObject var doc: Document
    var ctrl: SceneController?
    let node: PartTreeNode
    @Binding var expanded: Set<String>
    var body: some View {
        if let part = node.part { PartBrowserRow(doc:doc,ctrl:ctrl,part:part) }
        else {
            DisclosureGroup(isExpanded:Binding(get:{expanded.contains(node.path ?? node.id)},set:{ value in
                if value { expanded.insert(node.path ?? node.id) } else { expanded.remove(node.path ?? node.id) }
            })) {
                ForEach(node.children ?? []) { child in AssemblyTreeRow(doc:doc,ctrl:ctrl,node:child,expanded:$expanded) }
            } label: {
                Button { if let path = node.path { doc.selectAssembly(path) } } label: {
                    HStack(spacing:7) { Image(systemName:"folder").foregroundStyle(.secondary);Text(node.title).font(.callout.weight(.medium)).lineLimit(1);Spacer(minLength:3);Text("\(node.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }.padding(.vertical,7).contentShape(Rectangle())
                }.buttonStyle(.plain).help(node.path ?? node.title)
                .contextMenu {
                    if let path = node.path {
                        Button("Select Assembly") { doc.selectAssembly(path) }
                        Button("Isolate Assembly") { doc.selectAssembly(path);doc.isolateSelection = true }
                        Button("Hide Assembly") { doc.setPartsHidden(Set(doc.parts.filter { $0.group == path || $0.group?.hasPrefix(path+"/") == true }.map(\.id)),hidden:true) }.disabled(doc.workspaceInspectionOnly)
                    }
                }
            }
        }
    }
}

struct PartBrowserRow: View {
    @ObservedObject var doc: Document
    var ctrl: SceneController?
    let part: Part
    var searchCandidate = false
    @State private var hovered = false
    private var isSelected: Bool { doc.selectedIDs.contains(part.id) }
    private var subtitle: String { ShopIdentity.label(part)+" · "+part.species.rawValue }
    private var tooltip: String { subtitle+"\n"+part.name+"\n"+(part.group ?? "") }
    var body: some View {
        HStack(spacing:7) {
            Button {
                let extended = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                doc.select(part.id,extending:extended)
            } label: { label }.buttonStyle(.plain)
            if hovered || part.hidden == true { visibilityButton }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.13) : Color.clear,in:RoundedRectangle(cornerRadius:7))
        .overlay { if searchCandidate { RoundedRectangle(cornerRadius:7).strokeBorder(Color.accentColor,lineWidth:1) } }
        .opacity(part.hidden == true ? 0.5 : 1)
        .id(part.id)
        .onHover { hovered = $0 }
        .contextMenu { WorkspaceContextMenu(doc:doc,ctrl:ctrl,target:part.id) }
        .help(tooltip)
    }
    private var label: some View {
        HStack(spacing:8) {
            Image(systemName:part.hardware == true ? "wrench.and.screwdriver" : "cube").font(.callout).foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:3) {
                Text(part.name).font(.callout).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
    }
    private var visibilityButton: some View {
        Button { doc.setPartsHidden([part.id],hidden:part.hidden != true) } label: {
            Image(systemName:part.hidden == true ? "eye.slash" : "eye").font(.caption)
        }.buttonStyle(.borderless).disabled(doc.workspaceInspectionOnly).help(part.hidden == true ? "Show part" : "Hide part")
    }
}

struct MaterialIntentSection: View {
    @ObservedObject var doc: Document
    let part: Part
    var body: some View {
        GroupBox("Material & resizing") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Thickness axis", selection: Binding(get: { part.materialAxes.t }, set: { axis in
                    doc.edit(part.id) { p in
                        p.thicknessAxis = axis
                        if p.materialAxes.l == axis || p.grainDirection == axis { p.grainDirection = (0..<3).first { $0 != axis } }
                    }
                })) { ForEach(0..<3) { Text(FaceRef.axisNames[$0]).tag($0) } }
                Picker("Grain / length", selection: Binding(get: { part.materialAxes.l }, set: { axis in
                    doc.edit(part.id) { $0.grainDirection = axis }
                })) {
                    ForEach((0..<3).filter { $0 != part.materialAxes.t }, id: \.self) { Text(FaceRef.axisNames[$0]).tag($0) }
                }
                Toggle("Scale joinery with board", isOn: Binding(get: { part.resizeJoinery ?? false }, set: { v in
                    doc.edit(part.id) { $0.resizeJoinery = v }
                }))
                Text("Scaling changes joint offsets and dimensions proportionally. Leave off to keep machining sizes fixed.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }
}

struct RelationshipSection: View {
    @ObservedObject var doc: Document
    let part: Part
    @State private var source: UUID?
    @State private var sourceAxis = 0
    @State private var targetAxis = 0
    @State private var offset = 0.0
    private var incoming: [DimensionLink] { doc.links.filter { $0.target == part.id } }
    var body: some View {
        GroupBox("Linked dimensions") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(incoming) { link in
                    HStack {
                        Text("\(FaceRef.axisNames[link.targetAxis]) = \(doc.part(link.source)?.name ?? "Part") \(FaceRef.axisNames[link.sourceAxis]) + \(doc.fmt(link.offset))")
                            .font(.caption)
                        Spacer()
                        Button { doc.checkpoint(); doc.links.removeAll { $0.id == link.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("Remove relationship")
                    }
                }
                Picker("Source board", selection: $source) {
                    Text("Choose a board").tag(nil as UUID?)
                    ForEach(doc.parts.filter { $0.id != part.id }) { Text($0.name).tag(Optional($0.id)) }
                }
                HStack {
                    Picker("Source", selection: $sourceAxis) { ForEach(0..<3) { Text(FaceRef.axisNames[$0]).tag($0) } }
                    Picker("Target", selection: $targetAxis) { ForEach(0..<3) { Text(FaceRef.axisNames[$0]).tag($0) } }
                }
                DimField(label: "Offset", value: $offset, metric: doc.metric)
                Button("Link dimension") {
                    if let source { doc.addLink(DimensionLink(source: source, sourceAxis: sourceAxis, target: part.id, targetAxis: targetAxis, offset: offset)) }
                }.disabled(source == nil)
                Text("Target size follows source size plus offset. Enable joinery scaling above to resize its joints too.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }
}

struct JoineryEditor: View {
    @ObservedObject var doc: Document
    let part: Part
    var body: some View {
        GroupBox("Edit existing joinery") {
            VStack(alignment: .leading) {
                ForEach(part.cuts) { cut in
                    DisclosureGroup(cut.kind) {
                        CutEditor(doc: doc, partID: part.id, cut: cut)
                    }
                }
            }.padding(4)
        }
    }
}

struct CutEditor: View {
    @ObservedObject var doc: Document
    let partID: UUID
    let cut: Cut
    @State private var draft: Cut?
    @State private var error: String?
    private func bound(_ upper: Bool, axis: Int) -> Binding<Double> {
        Binding(get: { upper ? (draft ?? cut).hi[axis] : (draft ?? cut).lo[axis] }, set: { value in
            if draft == nil { draft = cut }
            if upper { draft?.hi[axis] = value } else { draft?.lo[axis] = value }
        })
    }
    private enum Parameter { case offset, width, depth, start, length }
    private func parameter(_ field: Parameter) -> Binding<Double> {
        Binding(get: {
            let c = draft ?? cut
            let a = c.faceAxis ?? 0, run = c.runAxis ?? ((a + 1) % 3)
            let across = (0..<3).first { $0 != a && $0 != run }!
            switch field {
            case .offset: return c.lo[across]
            case .width: return c.hi[across] - c.lo[across]
            case .depth: return c.hi[a] - c.lo[a]
            case .start: return c.lo[run]
            case .length: return c.hi[run] - c.lo[run]
            }
        }, set: { value in
            var c = draft ?? cut
            let a = c.faceAxis ?? 0, run = c.runAxis ?? ((a + 1) % 3)
            let across = (0..<3).first { $0 != a && $0 != run }!
            switch field {
            case .offset:
                c.hi[across] += value - c.lo[across]; c.lo[across] = value
            case .width: c.hi[across] = c.lo[across] + value
            case .start: c.hi[run] += value - c.lo[run]; c.lo[run] = value
            case .length: c.hi[run] = c.lo[run] + value
            case .depth:
                let size = doc.part(partID)?.size[a] ?? 0
                if c.additive {
                    c.lo[a] = c.facePositive == true ? size : -value
                    c.hi[a] = c.facePositive == true ? size + value : 0
                } else {
                    c.lo[a] = c.facePositive == true ? size - value : 0
                    c.hi[a] = c.facePositive == true ? size : value
                }
            }
            draft = c
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Type", selection: Binding(get: { (draft ?? cut).kind }, set: { kind in
                let depth = parameter(.depth).wrappedValue
                if draft == nil { draft = cut }; draft?.kind = kind
                if cut.faceAxis != nil { parameter(.depth).wrappedValue = depth }
            })) {
                ForEach(["Dado", "Rabbet", "Mortise", "Groove", "Tenon"], id: \.self) { Text($0).tag($0) }
            }
            if let axis = cut.faceAxis, cut.runAxis != nil {
                Text("Face \(FaceRef(part: partID, axis: axis, positive: cut.facePositive ?? true).label)").font(.caption).foregroundStyle(.secondary)
                DimField(label: "Offset", value: parameter(.offset), metric: doc.metric, minimum: 0)
                DimField(label: "Width", value: parameter(.width), metric: doc.metric, minimum: 1 / 1024)
                DimField(label: "Depth", value: parameter(.depth), metric: doc.metric, minimum: 1 / 1024)
                DimField(label: "Run start", value: parameter(.start), metric: doc.metric, minimum: 0)
                DimField(label: "Length", value: parameter(.length), metric: doc.metric, minimum: 1 / 1024)
            } else {
                Text("Local coordinates from the board’s minimum corner.").font(.caption).foregroundStyle(.secondary)
                ForEach(0..<3) { axis in
                    DimField(label: "Start \(FaceRef.axisNames[axis])", value: bound(false, axis: axis), metric: doc.metric)
                    DimField(label: "End \(FaceRef.axisNames[axis])", value: bound(true, axis: axis), metric: doc.metric)
                }
            }
            if !cut.additive { ReliefEditor(doc: doc, partID: partID, cut: cut) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Apply") {
                    guard var part = doc.part(partID) else { return }
                    let next = draft ?? cut
                    part.cuts = part.cuts.map { $0.id == cut.id ? next : $0 }
                    if let message = ModelValidation.part(part) { error = message; return }
                    doc.edit(partID) { $0.cuts = part.cuts }
                    draft = nil; error = nil
                }
                Button("Reset") { draft = nil; error = nil }
                Button("Delete", role: .destructive) { doc.edit(partID) { $0.cuts.removeAll { $0.id == cut.id } } }
            }
        }.padding(.vertical, 6)
        .onChange(of: cut) { _, _ in draft = nil; error = nil }
    }
}

struct TrimEditor: View {
    @ObservedObject var doc: Document
    let part: Part
    var body: some View {
        GroupBox("Edit angled cuts") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(part.trims) { trim in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(FaceRef(part: part.id, axis: trim.axis, positive: trim.positive).label).font(.caption)
                        AngleField(label: "Angle", value: Binding(get: { trim.angle }, set: { value in
                            doc.edit(part.id) { p in
                                if let i = p.trims.firstIndex(where: { $0.id == trim.id }) { p.trims[i].angle = value }
                            }
                        }), limit: 89.899)
                        Toggle("Long point on far edge", isOn: Binding(get: { trim.farEdge }, set: { value in
                            doc.edit(part.id) { p in
                                if let i = p.trims.firstIndex(where: { $0.id == trim.id }) { p.trims[i].farEdge = value }
                            }
                        }))
                        Button("Remove angled cut", role: .destructive) { doc.edit(part.id) { $0.trims.removeAll { $0.id == trim.id } } }
                    }
                }
            }.padding(4)
        }
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    let doc: Document
    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view, coordinator = context.coordinator] in
            guard let window = view?.window else { return }
            coordinator.original = window.delegate
            window.delegate = coordinator
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.window?.isDocumentEdited = doc.isDirty }
    final class Coordinator: NSObject, NSWindowDelegate {
        let doc: Document
        weak var original: NSWindowDelegate?
        init(doc: Document) { self.doc = doc }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            doc.confirmDiscard() && (original?.windowShouldClose?(sender) ?? true)
        }
        override func responds(to aSelector: Selector!) -> Bool { super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false) }
        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if original?.responds(to: aSelector) == true { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
