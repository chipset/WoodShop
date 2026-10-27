import SwiftUI
import AppKit

enum PartSearch {
    static func matches(_ query: String,in text: String) -> Bool {
        query.split(whereSeparator:\.isWhitespace).allSatisfy { text.localizedStandardContains(String($0)) }
    }
    static func matches(_ query: String,part: Part) -> Bool {
        matches(query,in:ShopIdentity.label(part)+" "+part.name+" "+(part.group ?? "")+" "+part.species.rawValue)
    }
}

enum CommandNavigation {
    static func next(in actions: [WorkspaceAction],from selection: WorkspaceAction?,step: Int,doc: Document) -> WorkspaceAction? {
        let available = actions.filter { $0.enabled(in:doc) }
        guard !available.isEmpty else { return nil }
        guard let selection,let index = available.firstIndex(of:selection) else { return available.first }
        return available[max(0,min(available.count-1,index+step))]
    }
}

struct PartTreeNode: Identifiable {
    var id: String
    var title: String
    var part: Part?
    var path: String?
    var children: [PartTreeNode]?
    var count: Int { part == nil ? children?.reduce(0) { $0+$1.count } ?? 0 : 1 }
    static func make(_ parts: [Part]) -> [PartTreeNode] {
        func nodes(_ items: [Part],prefix: [String]) -> [PartTreeNode] {
            let own = items.filter { ($0.group ?? "").split(separator:"/").count <= prefix.count }
            let grouped = Dictionary(grouping:items.filter { ($0.group ?? "").split(separator:"/").count > prefix.count }) { String(($0.group ?? "").split(separator:"/")[prefix.count]) }
            let folders = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key -> PartTreeNode in
                let path = (prefix+[key]).joined(separator:"/")
                return PartTreeNode(id:"assembly:"+path,title:key,path:path,children:nodes(grouped[key]!,prefix:prefix+[key]))
            }
            return folders+own.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { PartTreeNode(id:$0.id.uuidString,title:$0.name,part:$0) }
        }
        let result = nodes(parts,prefix:[])
        if result.count == 1,result[0].part == nil { return result[0].children ?? result }
        return result
    }
}

struct WorkspaceCommandPalette: View {
    @ObservedObject var doc: Document
    let ctrl: SceneController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: WorkspaceAction? = .addStock
    @FocusState private var searchFocused: Bool
    private var results: [WorkspaceAction] {
        let matches = WorkspaceAction.matching(query)
        guard query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return matches }
        let common: [WorkspaceAction] = [.projectPreset,.addStock,.addPanel,.parameters,.machine,.cnc,.fitSelection,.fitAll]
        return common+matches.filter { !common.contains($0) }
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands…",text:$query).textFieldStyle(.plain).font(.title3).focused($searchFocused).onSubmit(execute)
                    .onKeyPress(.upArrow) { move(-1);return .handled }
                    .onKeyPress(.downArrow) { move(1);return .handled }
                    .accessibilityLabel("Search WoodShop commands")
                Text("esc").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }.padding(20)
            Divider()
            if results.isEmpty {
                VStack(spacing:10) { Image(systemName:"magnifyingglass").font(.title);Text("No matching commands").font(.headline);Text("Try “part”, “view”, or “CNC”.").foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing:3) {
                            ForEach(results) { action in
                                Button { selection = action;execute() } label: {
                                    HStack(spacing:12) {
                                        Image(systemName:action.symbol).frame(width:22).foregroundStyle(.secondary)
                                        Text(action.title)
                                        Spacer()
                                        Text(action.category).font(.caption).foregroundStyle(.secondary)
                                        if !action.enabled(in:doc) { Text(action.needsSelection && doc.selectedPart == nil ? "Select a part" : "Unavailable").font(.caption).foregroundStyle(.tertiary) }
                                    }.padding(12).contentShape(Rectangle())
                                        .foregroundStyle(action.enabled(in:doc) ? Color.primary : .secondary)
                                        .background(selection == action ? Color.accentColor.opacity(0.12) : Color.clear,in:RoundedRectangle(cornerRadius:8))
                                }.buttonStyle(.plain).disabled(!action.enabled(in:doc)).id(action)
                            }
                        }.padding(10)
                    }
                    .onChange(of:selection) { _,id in if let id { proxy.scrollTo(id,anchor:.center) } }
                }
            }
            Divider()
            HStack { Text("↑ ↓ to navigate");Spacer();Text("Return to run") }.font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(width:650,height:480).background(Color(nsColor:.windowBackgroundColor))
        .onAppear { searchFocused = true;selectFirst() }
        .onChange(of:query) { _,_ in selectFirst() }
        .onMoveCommand { direction in
            guard direction == .up || direction == .down,!results.isEmpty else { return }
            move(direction == .up ? -1 : 1)
        }
        .onExitCommand { dismiss() }
    }
    private func selectFirst() { selection = results.first { $0.enabled(in:doc) } ?? results.first }
    private func move(_ step: Int) { selection = CommandNavigation.next(in:results,from:selection,step:step,doc:doc) }
    private func execute() {
        guard let selection,selection.enabled(in:doc) else { return }
        dismiss()
        DispatchQueue.main.async { selection.run(doc:doc,ctrl:ctrl) }
    }
}

struct StockPopover: View {
    @ObservedObject var doc: Document
    let ctrl: SceneController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Label("Add stock",systemImage:"plus.square").font(.headline)
            Picker("Stock",selection:$doc.stock) { ForEach(Stock.all) { Text($0.name).tag($0) } }
            Picker("Material",selection:$doc.species) { ForEach(Species.allCases) { Text($0.rawValue).tag($0) } }
            DimField(label:"Length",value:$doc.stockLength,metric:doc.metric,minimum:1/32)
            Button("Start from a cabinet, drawer, shelf, or workbench…") { dismiss();DispatchQueue.main.async { doc.showProjectPreset = true } }
            Divider()
            HStack { Button("Plywood panel") { WorkspaceAction.addPanel.run(doc:doc,ctrl:ctrl);dismiss() };Spacer();Button("Add Board") { WorkspaceAction.addStock.run(doc:doc,ctrl:ctrl);dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width:360)
    }
}

struct ViewportHUD: View {
    @ObservedObject var doc: Document
    let ctrl: SceneController
    var body: some View {
        VStack {
            HStack {
                HStack(spacing:8) {
                    Image(systemName:doc.tool.symbol).foregroundStyle(Color.accentColor)
                    Text(doc.tool.title).fontWeight(.medium)
                    if !doc.selectedIDs.isEmpty { Divider().frame(height:14);Text("\(doc.selectedIDs.count) selected").foregroundStyle(.secondary) }
                }.font(.callout).padding(.horizontal,12).padding(.vertical,8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                Spacer()
                Menu {
                    Button("Isometric") { WorkspaceAction.isoView.run(doc:doc,ctrl:ctrl) }
                    Button("Top") { WorkspaceAction.topView.run(doc:doc,ctrl:ctrl) }
                    Button("Front") { WorkspaceAction.frontView.run(doc:doc,ctrl:ctrl) }
                    Button("Right") { ctrl.setView(yaw:.pi/2,pitch:0) }
                    Divider()
                    Toggle("Orthographic",isOn:Binding(get:{ctrl.ortho},set:{ctrl.ortho = $0}))
                    Toggle("Editable dimensions",isOn:$doc.showEditableDimensions)
                    if !doc.studio.scenes.isEmpty { Divider();ForEach(doc.studio.scenes) { scene in Button(scene.name) { ctrl.restoreScene(scene) } } }
                } label: { Label("Views",systemImage:"cube") }.menuStyle(.borderlessButton).fixedSize().padding(9).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).help("Camera and saved views")
                Button { ctrl.zoomExtents() } label: { Image(systemName:"arrow.up.left.and.down.right.magnifyingglass").frame(width:34,height:34) }.buttonStyle(.plain).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).help("Zoom to fit · ⌘0").accessibilityLabel("Zoom to fit")
            }
            Spacer()
            if !doc.parts.isEmpty {
                HStack { Text("Right-click for actions  ·  Option-drag to orbit  ·  Shift–Option-drag to pan").font(.caption).foregroundStyle(.secondary).padding(9).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8));Spacer() }
            }
        }.padding(14).allowsHitTesting(true)
    }
}

struct MultiSelectionInspector: View {
    @ObservedObject var doc: Document
    @State private var axis = 0
    @State private var maximum = false
    @State private var groupName = ""
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Selection").font(.headline)
            Text("\(doc.selectedIDs.count) parts selected").foregroundStyle(.secondary)
            HStack { Button("Duplicate") { doc.duplicateSelected() };Button("Isolate") { doc.isolateSelection.toggle() };Button("Hide") { doc.setPartsHidden(doc.selectedIDs,hidden:true) } }
            GroupBox("Align parts") {
                VStack(alignment:.leading,spacing:10) {
                    Text("Align to \(doc.selectedPart?.name ?? "the active part").").font(.caption).foregroundStyle(.secondary)
                    Picker("Axis",selection:$axis) { ForEach(0..<3) { Text(FaceRef.axisNames[$0]).tag($0) } }.pickerStyle(.segmented)
                    Toggle("Use maximum edge",isOn:$maximum)
                    Button("Align selection") { doc.alignSelected(axis:axis,maximum:maximum) }
                    Button("Keep aligned when dimensions change…") { doc.openMake(.relationships) }
                }.padding(6)
            }
            GroupBox("Assembly") {
                VStack(alignment:.leading,spacing:10) {
                    TextField("Assembly name",text:$groupName).textFieldStyle(.roundedBorder)
                    Button("Group selected parts") { doc.setGroup(groupName) }.disabled(groupName.trimmingCharacters(in:.whitespaces).isEmpty)
                }.padding(6)
            }
            ForEach(doc.parts.filter { doc.selectedIDs.contains($0.id) }.prefix(12)) { part in
                HStack { Text(ShopIdentity.label(part)).font(.caption.monospaced()).foregroundStyle(.secondary);Text(part.name).lineLimit(1) }
            }
            if doc.selectedIDs.count > 12 { Text("+ \(doc.selectedIDs.count-12) more parts").font(.caption).foregroundStyle(.secondary) }
            Button("More transform tools…") { doc.workshopTab = 1;doc.showWorkshop = true }
            Button("Check assembly clearances…") { doc.openMake(.assemblyChecks) }
        }
    }
}

struct CompactFeatureHistory: View {
    @ObservedObject var doc: Document
    let part: Part
    @State private var failure = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("Feature history").font(.headline);Spacer();Button { doc.showDesign = true } label: { Image(systemName:"arrow.up.right.square") }.buttonStyle(.borderless).help("Open full history editor") }
            Text("Change a feature and later steps regenerate.").font(.caption).foregroundStyle(.secondary)
            Button { doc.historyInspection = HistoryInspection(part:part.id,through:0) } label: { Label("Source blank / profile",systemImage:"cube") }.buttonStyle(.bordered).frame(maxWidth:.infinity,alignment:.leading)
            ForEach(Array(part.featureSteps.enumerated()),id:\.element.id) { index,step in
                let ref = FeatureRef(part:part.id,kind:step.kind,feature:step.feature)
                HStack(spacing:8) {
                    FeatureThumbnail(part:part,step:step).frame(width:38,height:38)
                    Button { doc.resumeFeatureHistory();doc.selectFeature(ref);doc.showFeatureEditor = true } label: { Text(part.featureName(step)).frame(maxWidth:.infinity,alignment:.leading).lineLimit(2) }.buttonStyle(.plain)
                    Menu {
                        Button("Edit…") { doc.resumeFeatureHistory();doc.selectFeature(ref);doc.showFeatureEditor = true }
                        Button("Preview through this step") { doc.historyInspection = HistoryInspection(part:part.id,through:index+1) }
                        Button(part.featureSuppressed(step) ? "Enable feature" : "Suppress feature") {
                            failure = doc.setFeatureSuppressed(ref,!part.featureSuppressed(step)) ? "" : doc.status
                            if !failure.isEmpty { doc.selectFeature(ref) }
                        }.disabled(doc.workspaceInspectionOnly)
                        Divider()
                        Button("Move earlier") { doc.reorderFeature(ref,delta:-1) }.disabled(index == 0)
                        Button("Move later") { doc.reorderFeature(ref,delta:1) }.disabled(index == part.featureSteps.count-1)
                    } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for "+part.featureName(step))
                }.padding(10).background(doc.selectedFeature == ref ? Color.accentColor.opacity(0.12) : Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                .opacity(part.featureSuppressed(step) ? 0.55 : 1)
                if part.featureSuppressed(step) { Text("Suppressed · step \(index+1)").font(.caption2).foregroundStyle(.secondary) }
            }
            ForEach((doc.studio.matingJoints ?? []).filter { $0.receiver == part.id && $0.suppressed }) { joint in
                Button("Enable "+joint.label+" · "+joint.name) {
                    let success = doc.transaction { if let i = doc.studio.matingJoints?.firstIndex(where: { $0.id == joint.id }) { doc.studio.matingJoints![i].suppressed = false } }
                    failure = success ? "" : doc.status
                }.disabled(doc.workspaceInspectionOnly)
            }
            if !failure.isEmpty { Text(failure).font(.caption).foregroundStyle(.red);Text("Edit the highlighted feature or its driving parameters, then retry.").font(.caption).foregroundStyle(.secondary) }
            if part.featureSteps.isEmpty { Text("No machining features yet. Use Machining to add holes and joinery.").font(.callout).foregroundStyle(.secondary) }
            if doc.historyInspection != nil { Button("Resume finished part") { doc.resumeFeatureHistory() }.buttonStyle(.borderedProminent) }
            Divider()
            Button("Named parameters & revisions…") { doc.showDesign = true }
        }
    }
}
