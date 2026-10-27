import SwiftUI
import AppKit

enum Shared {
    static let doc = Document()
    static let ctrl = SceneController(doc: Shared.doc)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Shared.doc.recoverIfAvailable()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { Shared.doc.open(url: url) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Shared.doc.confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// True (after performing it) when a text field is being edited.
@MainActor func forwardToText(_ action: Selector) -> Bool {
    guard NSApp.keyWindow?.firstResponder is NSText else { return false }
    return NSApp.sendAction(action, to: nil, from: nil)
}

@main
struct WoodShopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var doc = Shared.doc

    var body: some Scene {
        Window("WoodShop", id: "main") {
            ContentView(doc: doc, ctrl: Shared.ctrl)
                .frame(minWidth: 1200, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { doc.newDocument() }.keyboardShortcut("n")
                Button("Insert Woodworking Project…") { doc.showProjectPreset = true }.keyboardShortcut("n",modifiers:[.command,.shift]).disabled(doc.workspaceInspectionOnly)
                Button("New Garage Cabinet Project") { doc.newGarageCabinetProject(); Shared.ctrl.zoomExtents() }
                Button("Open…") { doc.open() }.keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(Recents.urls, id: \.path) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { doc.open(url: url) }
                    }
                    Divider()
                    Button("Clear Menu") { Recents.clear() }
                }
                Button("Save") { doc.save() }.keyboardShortcut("s")
                Button("Restore Previous Saved Version") { doc.restorePreviousSave() }.disabled(!doc.canRestorePreviousSave)
                Button("Save As…") { doc.save(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .importExport) {
                Button("Import 3D Model or Outline…") { doc.importGeometry() }
                Button("Export VCarve Job…") { doc.openMake(.sheets) }
                Menu("Export 3D Model") {
                    ForEach(MeshFormat.allCases) { format in
                        if format.carriesUnits { Button(format.title + "…") { doc.exportMesh(format, millimeters: false) } }
                        else {
                            Button(format.title + " (mm)…") { doc.exportMesh(format, millimeters: true) }
                            Button(format.title + " (inches)…") { doc.exportMesh(format, millimeters: false) }
                        }
                    }
                }
                Button("Export Flat DXF for VCarve…") { doc.exportFlat(svg: false) }
                Button("Export Part Labels (PDF)…") { doc.exportShopLabels() }
                Button("Export Assembly Guide (PDF)…") { doc.exportAssemblyGuide() }
                Button("Export Shop Drawings (PDF)…") { doc.exportDrawings() }
                Button("Export Exploded Assembly (PDF)…") { doc.exportExplodedGuide() }
            }
            CommandGroup(replacing: .pasteboard) {
                // In a text field these behave normally; elsewhere they act on boards.
                Button("Cut") { if !forwardToText(#selector(NSText.cut(_:))) { doc.cutBoards() } }.keyboardShortcut("x")
                Button("Copy") { if !forwardToText(#selector(NSText.copy(_:))) { doc.copyBoards() } }.keyboardShortcut("c")
                Button("Paste") { if !forwardToText(#selector(NSText.paste(_:))) { doc.pasteBoards() } }.keyboardShortcut("v")
                Button("Select All") { if !forwardToText(#selector(NSText.selectAll(_:))) { doc.selectAllBoards() } }.keyboardShortcut("a")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { doc.undo() }.keyboardShortcut("z").disabled(!doc.canUndo || doc.faceSketchEditorActive)
                Button("Redo") { doc.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!doc.canRedo || doc.faceSketchEditorActive)
            }
            CommandMenu("Model") {
                Button("Find a Part…") { WorkspaceAction.findPart.run(doc:doc,ctrl:Shared.ctrl) }.keyboardShortcut("f")
                Button("Search Commands…") { doc.showCommandPalette = true }.keyboardShortcut("k")
                Button("Show / Hide Parts") { doc.showPartsSidebar.toggle() }.keyboardShortcut("1",modifiers:[.command,.option])
                Button("Show / Hide Inspector") { doc.showInspector.toggle() }.keyboardShortcut("i",modifiers:[.command,.option])
                Button("Zoom to Selection") { Shared.ctrl.zoomSelection() }.keyboardShortcut("f",modifiers:[.command,.shift])
                Button("Show All Parts") { doc.showAllParts() }
                Divider()
                Button("Parameters & History…") { doc.showDesign = true }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Workshop…") { doc.showWorkshop = true }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Shop Planning…") { doc.openMake(.materials) }.keyboardShortcut("j",modifiers:[.command,.shift])
                Button("Make Component") { doc.makeComponents() }
                Button("Make Unique") { doc.makeComponents(unique: true) }
                Button("Add Board") { doc.addStock() }.keyboardShortcut("b")
                Button("Duplicate") { doc.duplicateSelected() }.keyboardShortcut("d")
                Button("Zoom to Fit") { Shared.ctrl.zoomExtents() }.keyboardShortcut("0")
                Button("Cut List…") { doc.openMake(.cutList) }.keyboardShortcut("l")
            }
        }
    }
}
