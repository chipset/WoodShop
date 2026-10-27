import AppKit
import SwiftUI

enum InspectorPage: String,CaseIterable { case part = "Part", machining = "Machining", history = "History" }

enum WorkspaceAction: String,CaseIterable,Identifiable {
    case inspect,rename,machine,sketchFace,editFeature,history,parameters,duplicate,delete,hide,showSelection,isolate,showAll,selectAssembly,makeUnique,makeComponent
    case fitSelection,fitAll,selectAll,deselect,addStock,addPanel,projectPreset,undo,redo,cnc,topView,frontView,isoView,toggleInspector,findPart
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inspect:return "Inspect Part"
        case .rename:return "Rename Part"
        case .machine:return "Machine Part…"
        case .sketchFace:return "Sketch on Face…"
        case .editFeature:return "Edit Machining Feature…"
        case .history:return "Part Feature History"
        case .parameters:return "Parameters & Design History…"
        case .duplicate:return "Duplicate"
        case .delete:return "Delete Selected Parts"
        case .hide:return "Hide Selection"
        case .showSelection:return "Show Selection"
        case .isolate:return "Isolate Selection"
        case .showAll:return "Show All Parts"
        case .selectAssembly:return "Select Assembly"
        case .makeUnique:return "Make Unique"
        case .makeComponent:return "Make Component"
        case .fitSelection:return "Zoom to Selection"
        case .fitAll:return "Zoom to Fit"
        case .selectAll:return "Select All Visible Parts"
        case .deselect:return "Deselect All"
        case .addStock:return "Add Stock Board"
        case .addPanel:return "Add Plywood Panel"
        case .projectPreset:return "Create Cabinet, Drawer, Shelf, or Workbench…"
        case .undo:return "Undo"
        case .redo:return "Redo"
        case .cnc:return "Prepare CNC Job…"
        case .topView:return "Top View"
        case .frontView:return "Front View"
        case .isoView:return "Isometric View"
        case .toggleInspector:return "Show / Hide Inspector"
        case .findPart:return "Find a Part…"
        }
    }
    func menuTitle(in doc: Document) -> String { self == .isolate && doc.isolateSelection ? "End Isolation" : title }
    var symbol: String {
        switch self {
        case .inspect,.toggleInspector:return "sidebar.right"
        case .rename:return "pencil"
        case .findPart:return "magnifyingglass"
        case .machine:return "hammer"
        case .sketchFace:return "pencil.and.outline"
        case .editFeature:return "slider.horizontal.3"
        case .history:return "clock.arrow.circlepath"
        case .parameters:return "function"
        case .duplicate:return "plus.square.on.square"
        case .delete:return "trash"
        case .hide:return "eye.slash"
        case .isolate:return "viewfinder"
        case .showAll,.showSelection:return "eye"
        case .selectAssembly:return "square.stack.3d.up"
        case .makeUnique:return "square.on.square.dashed"
        case .makeComponent:return "shippingbox"
        case .fitSelection,.fitAll:return "arrow.up.left.and.down.right.magnifyingglass"
        case .selectAll:return "checkmark.circle"
        case .deselect:return "xmark.circle"
        case .addStock,.addPanel:return "plus"
        case .projectPreset:return "square.stack.3d.up"
        case .undo:return "arrow.uturn.backward"
        case .redo:return "arrow.uturn.forward"
        case .cnc:return "square.grid.3x3"
        case .topView,.frontView,.isoView:return "cube"
        }
    }
    var category: String {
        switch self {
        case .addPanel,.addStock,.projectPreset,.sketchFace:return "Create"
        case .topView,.frontView,.isoView,.fitAll,.fitSelection,.showAll,.showSelection,.hide,.isolate,.toggleInspector,.findPart:return "View"
        case .machine,.editFeature,.cnc:return "Fabrication"
        case .parameters,.history:return "Design"
        default:return "Edit"
        }
    }
    var needsSelection: Bool {
        switch self {
        case .inspect,.rename,.machine,.sketchFace,.editFeature,.history,.duplicate,.delete,.hide,.showSelection,.isolate,.selectAssembly,.makeUnique,.makeComponent,.fitSelection:return true
        default:return false
        }
    }
    var changesDesign: Bool {
        switch self {
        case .rename,.duplicate,.delete,.hide,.showSelection,.makeUnique,.makeComponent,.addStock,.addPanel,.projectPreset,.undo,.redo:return true
        default:return false
        }
    }
    func enabled(in doc: Document,target: UUID? = nil) -> Bool {
        let part = target.flatMap(doc.part) ?? doc.selectedPart
        if needsSelection && part == nil { return false }
        if changesDesign && doc.workspaceInspectionOnly { return false }
        switch self {
        case .editFeature:return doc.selectedFeature != nil && doc.selectedFeature?.part == part?.id && !doc.workspaceInspectionOnly
        case .machine:return !doc.workspaceInspectionOnly && part?.hardware != true
        case .sketchFace:return !doc.workspaceInspectionOnly && part?.hardware != true && part?.mesh == nil
        case .undo:return doc.canUndo
        case .redo:return doc.canRedo
        case .cnc:return !doc.parts.isEmpty && !doc.workspaceInspectionOnly
        case .fitAll,.selectAll:return !doc.parts.isEmpty
        case .deselect:return !doc.selectedIDs.isEmpty
        case .selectAssembly:return !(part?.group ?? "").isEmpty
        case .makeUnique:return part?.component != nil
        default:return true
        }
    }
    func run(doc: Document,ctrl: SceneController?,target: UUID? = nil) {
        guard enabled(in:doc,target:target) else { return }
        if let target,needsSelection { doc.focusContextPart(target) }
        switch self {
        case .inspect:doc.showInspector = true;doc.inspectorPage = .part
        case .rename:doc.showInspector = true;doc.inspectorPage = .part;doc.renamePartID = doc.selection
        case .machine:doc.showMachiningRecipes = true
        case .sketchFace:doc.beginFaceSketch()
        case .editFeature:doc.showFeatureEditor = true
        case .history:doc.showInspector = true;doc.inspectorPage = .history
        case .parameters:doc.showDesign = true
        case .duplicate:doc.duplicateSelected()
        case .delete:doc.deleteSelected()
        case .hide:doc.setPartsHidden(doc.selectedIDs,hidden:true)
        case .showSelection:doc.setPartsHidden(doc.selectedIDs,hidden:false)
        case .isolate:doc.isolateSelection.toggle()
        case .showAll:doc.showAllParts()
        case .selectAssembly:if let group = doc.selectedPart?.group { doc.selectAssembly(group) }
        case .makeUnique:doc.makeComponents(unique:true)
        case .makeComponent:doc.makeComponents()
        case .fitSelection:ctrl?.zoomSelection()
        case .fitAll:ctrl?.zoomExtents()
        case .selectAll:doc.finishDrag?();doc.selectedIDs = Set(doc.parts.filter(doc.isVisible).map(\.id));doc.selection = doc.selectedIDs.first
        case .deselect:doc.finishDrag?();doc.selection = nil;doc.selectedFeature = nil;doc.selectedFace = nil
        case .addStock:doc.addStock();ctrl?.zoomSelection()
        case .projectPreset:doc.showProjectPreset = true
        case .addPanel:
            var p = Part(name:doc.nextName("Panel"),origin:.zero,size:SIMD3(24,0.75,16),species:.plywood)
            p.thicknessAxis = 1;p.grainDirection = 0;doc.add(p);ctrl?.zoomSelection()
        case .undo:doc.undo()
        case .redo:doc.redo()
        case .cnc:doc.beginCNCJob()
        case .topView:ctrl?.setView(yaw:0,pitch:1.553)
        case .frontView:ctrl?.setView(yaw:0,pitch:0)
        case .isoView:ctrl?.setView(yaw:0.7,pitch:0.5)
        case .toggleInspector:doc.showInspector.toggle()
        case .findPart:doc.showPartsSidebar = true;doc.focusPartSearch = UUID()
        }
    }
    static func matching(_ query: String) -> [WorkspaceAction] {
        let words = query.lowercased().split(whereSeparator:\.isWhitespace)
        return allCases.filter { action in words.allSatisfy { (action.title+" "+action.category+(action == .sketchFace ? " curve arc circle ellipse bezier bézier groove pocket" : "")).lowercased().contains($0) } }
    }
}

extension Document {
    var workspaceInspectionOnly: Bool { parameterPreview != nil || historyInspection != nil || faceSketchEditorActive }
    func focusContextPart(_ id: UUID) {
        guard part(id) != nil else { return }
        finishDrag?()
        if selectedIDs.contains(id) { selection = id } else { select(id) }
        if selectedFeature?.part != id { selectedFeature = nil }
    }
    func setPartsHidden(_ ids: Set<UUID>,hidden: Bool) {
        guard !workspaceInspectionOnly,parts.contains(where: { ids.contains($0.id) && ($0.hidden ?? false) != hidden }) else { return }
        transaction { for i in parts.indices where ids.contains(parts[i].id) { parts[i].hidden = hidden } }
    }
    func showAllParts() {
        isolateSelection = false
        setPartsHidden(Set(parts.map(\.id)),hidden:false)
    }
}
extension SceneController {
    func zoomSelection() {
        let selected = doc.parts.filter { doc.selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { zoomExtents();return }
        var lo = SIMD3<Double>(repeating:.infinity),hi = SIMD3<Double>(repeating:-.infinity)
        for part in selected { lo = pointwiseMin(lo,part.bounds.lo);hi = pointwiseMax(hi,part.bounds.hi) }
        target = (lo+hi)/2;distance = max(12,norm(hi-lo)/2/sin(fov * .pi/360)*1.2);updateCamera()
    }
}

struct WorkspaceContextMenu: View {
    @ObservedObject var doc: Document
    var ctrl: SceneController?
    var target: UUID?
    var feature = false
    var body: some View {
        if target != nil {
            if feature { item(.editFeature);Divider() }
            item(.inspect);item(.rename);item(.sketchFace);item(.machine);item(.history)
            Divider()
            item(.fitSelection);item(.isolate);item(target.flatMap(doc.part)?.hidden == true ? .showSelection : .hide);item(.selectAssembly)
            Divider()
            item(.duplicate);item(.makeComponent);item(.makeUnique)
            Divider()
            Button(role:.destructive) { WorkspaceAction.delete.run(doc:doc,ctrl:ctrl,target:target) } label: { Label("Delete Part\(doc.selectedIDs.count > 1 && target.map(doc.selectedIDs.contains) == true ? "s" : "")",systemImage:"trash") }
                .disabled(!WorkspaceAction.delete.enabled(in:doc,target:target))
        } else {
            item(.addStock);item(.addPanel);Divider();item(.fitAll);item(.showAll);item(.parameters);item(.cnc)
        }
    }
    private func item(_ action: WorkspaceAction) -> some View {
        Button { action.run(doc:doc,ctrl:ctrl,target:target) } label: { Label(action.menuTitle(in:doc),systemImage:action.symbol) }
            .disabled(!action.enabled(in:doc,target:target))
    }
}

/// Native menu actions and the SwiftUI menu share the same command behavior.
final class NativeMenuAction: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func invoke(_ sender: NSMenuItem) { perform() }
}
enum WorkspaceMenus {
    static func make(doc: Document,ctrl: SceneController?,part: UUID?,feature: Bool = false) -> NSMenu {
        let menu = NSMenu(title:"WoodShop");menu.autoenablesItems = false
        func item(_ action: WorkspaceAction,title: String? = nil) {
            let handler = NativeMenuAction { action.run(doc:doc,ctrl:ctrl,target:part) }
            let row = NSMenuItem(title:title ?? action.menuTitle(in:doc),action:#selector(NativeMenuAction.invoke(_:)),keyEquivalent:"")
            row.target = handler;row.representedObject = handler;row.isEnabled = action.enabled(in:doc,target:part)
            row.image = NSImage(systemSymbolName:action.symbol,accessibilityDescription:nil);menu.addItem(row)
        }
        if part != nil {
            if feature { item(.editFeature);menu.addItem(.separator()) }
            [.inspect,.rename,.sketchFace,.machine,.history].forEach { item($0) };menu.addItem(.separator())
            [WorkspaceAction.fitSelection,.isolate,part.flatMap(doc.part)?.hidden == true ? .showSelection : .hide,.selectAssembly].forEach { item($0) };menu.addItem(.separator())
            [.duplicate,.makeComponent,.makeUnique].forEach { item($0) };menu.addItem(.separator());item(.delete,title:"Delete Selected Part\(doc.selectedIDs.count > 1 ? "s" : "")")
        } else {
            [.addStock,.addPanel].forEach { item($0) };menu.addItem(.separator())
            [.fitAll,.showAll,.parameters,.cnc].forEach { item($0) }
            let views = NSMenu(title:"Standard Views");let parent = NSMenuItem(title:"Standard Views",action:nil,keyEquivalent:"")
            for action in [WorkspaceAction.isoView,.frontView,.topView] {
                let handler = NativeMenuAction { action.run(doc:doc,ctrl:ctrl) };let row = NSMenuItem(title:action.title,action:#selector(NativeMenuAction.invoke(_:)),keyEquivalent:"")
                row.target = handler;row.representedObject = handler;views.addItem(row)
            }
            parent.submenu = views;menu.addItem(parent)
        }
        return menu
    }
}
