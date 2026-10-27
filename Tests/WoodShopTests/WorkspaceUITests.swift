import XCTest
import SwiftUI
import SceneKit
@testable import WoodShop

final class WorkspaceUITests: XCTestCase {
    func document() -> WoodShop.Document { WoodShop.Document(startRecoveryTimer:false,recoveryLocation:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    func board(_ name: String = "Shelf",x: Double = 0) -> Part {
        var part = Part(name:name,origin:SIMD3(x,0,0),size:SIMD3(10,0.75,6),species:.plywood)
        part.thicknessAxis = 1;part.grainDirection = 0;return part
    }
    func testAssemblyTreePreservesAllPartsAndNaturalOrder() {
        var a = board("Side"),b = board("Bottom"),c = board("Door"),d = board("Loose")
        a.group = "Cabinet/Drawer 10";b.group = "Cabinet/Drawer 2";c.group = "Cabinet/Doors";d.group = nil
        let tree = PartTreeNode.make([a,b,c,d])
        XCTAssertEqual(tree.reduce(0) { $0+$1.count },4)
        let cabinet = tree.first { $0.path == "Cabinet" }!
        XCTAssertEqual(cabinet.children?.map(\.title),["Doors","Drawer 2","Drawer 10"])
        func ids(_ nodes: [PartTreeNode]) -> [UUID] { nodes.flatMap { node in node.part.map { [$0.id] } ?? ids(node.children ?? []) } }
        XCTAssertEqual(Set(ids(tree)),Set([a,b,c,d].map(\.id)))
        XCTAssertEqual(PartTreeNode.make([a,b,c]).reduce(0) { $0+$1.count },3)
    }
    func testTargetedActionsPreserveMultiSelectionAndUndo() {
        let d = document(),a = board("A"),b = board("B",x:14);d.add(a);d.add(b)
        d.select(a.id);d.select(b.id,extending:true)
        WorkspaceAction.duplicate.run(doc:d,ctrl:nil,target:a.id)
        XCTAssertEqual(d.parts.count,4);XCTAssertEqual(d.selectedIDs.count,2)
        d.undo();XCTAssertEqual(d.parts.count,2)
        d.select(b.id)
        WorkspaceAction.inspect.run(doc:d,ctrl:nil,target:a.id)
        XCTAssertEqual(d.selectedIDs,[a.id]);XCTAssertTrue(d.showInspector);XCTAssertEqual(d.inspectorPage,.part)
        WorkspaceAction.history.run(doc:d,ctrl:nil,target:a.id);XCTAssertEqual(d.inspectorPage,.history)
    }
    func testHideShowAllAndIsolationAreConsistentAndUndoable() {
        let d = document(),a = board(),b = board("Other",x:14);d.add(a);d.add(b);d.select(a.id)
        WorkspaceAction.hide.run(doc:d,ctrl:nil)
        XCTAssertEqual(d.part(a.id)?.hidden,true)
        d.isolateSelection = true;WorkspaceAction.showAll.run(doc:d,ctrl:nil)
        XCTAssertFalse(d.isolateSelection);XCTAssertEqual(d.part(a.id)?.hidden,false)
        d.undo();XCTAssertEqual(d.part(a.id)?.hidden,true)
        WorkspaceAction.showSelection.run(doc:d,ctrl:nil,target:a.id);XCTAssertEqual(d.part(a.id)?.hidden,false)
        let before = d.project;d.showAllParts();XCTAssertEqual(d.project,before,"Showing an already visible scene must be a no-op.")
    }
    func testMenusDisableEditsDuringHistoryInspection() {
        _ = NSApplication.shared
        let d = document(),p = board();d.add(p);d.historyInspection = HistoryInspection(part:p.id,through:0)
        let before = d.project,menu = WorkspaceMenus.make(doc:d,ctrl:nil,part:p.id)
        XCTAssertFalse(menu.items.first { $0.title.contains("Delete") }!.isEnabled)
        XCTAssertFalse(menu.items.first { $0.title == "Duplicate" }!.isEnabled)
        WorkspaceAction.delete.run(doc:d,ctrl:nil,target:p.id);XCTAssertEqual(d.project,before)
        XCTAssertTrue(WorkspaceAction.inspect.enabled(in:d));XCTAssertFalse(WorkspaceAction.cnc.enabled(in:d))
    }
    func testNativeMenuInvokesActionsAndBackgroundMenuIsSafe() {
        _ = NSApplication.shared
        let d = document(),a = board(),b = board("Other",x:14);d.add(a);d.add(b);d.select(b.id)
        let menu = WorkspaceMenus.make(doc:d,ctrl:nil,part:a.id)
        menu.performActionForItem(at:menu.indexOfItem(withTitle:"Duplicate"))
        XCTAssertEqual(d.parts.count,3);XCTAssertEqual(d.selectedPart?.name,a.name+" copy")
        let background = WorkspaceMenus.make(doc:d,ctrl:nil,part:nil)
        XCTAssertNotNil(background.items.first { $0.title == "Add Stock Board" })
        XCTAssertFalse(background.items.contains { $0.title.contains("Delete") })
        let op = try! JoineryTools.holes(part:d.part(a.id)!,axis:1,positive:true,centers:[SIMD2(2,2)],diameter:0.25,depth:0.5)[0]
        d.edit(a.id) { $0.operations = [op] }
        d.selectFeature(FeatureRef(part:a.id,kind:.operation,feature:op.id))
        let featureMenu = WorkspaceMenus.make(doc:d,ctrl:nil,part:a.id,feature:true)
        let index = featureMenu.indexOfItem(withTitle:"Edit Machining Feature…")
        XCTAssertGreaterThanOrEqual(index,0);XCTAssertTrue(featureMenu.items[index].isEnabled)
        featureMenu.performActionForItem(at:index);XCTAssertTrue(d.showFeatureEditor)
    }
    func testRightClickMenuTargetsHitPartAndRetainsSelectedAssembly() throws {
        _ = NSApplication.shared
        let d = document(),a = board(),b = board("Other",x:14);d.add(a);d.add(b);d.select(a.id);d.select(b.id,extending:true)
        let ctrl = SceneController(doc:d);ctrl.target = a.center;ctrl.distance = 35;ctrl.updateCamera()
        let view = ModelView(frame:CGRect(x:0,y:0,width:800,height:600));view.doc = d;view.ctrl = ctrl;view.scene = ctrl.scene;view.pointOfView = ctrl.cameraNode;view.connectActions()
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        let p = view.projectPoint(vec(a.center))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseUp,location:CGPoint(x:CGFloat(p.x),y:CGFloat(p.y)),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        let menu = try XCTUnwrap(view.menu(for:event))
        XCTAssertEqual(d.selection,a.id);XCTAssertEqual(d.selectedIDs,[a.id,b.id])
        XCTAssertNotNil(menu.items.first { $0.title == "Machine Part…" })
    }
    func testZoomToFitHonorsIsolatedAndHiddenParts() {
        let d = document(),a = board(),b = board("Distant",x:200);d.add(a);d.add(b);d.select(a.id)
        let ctrl = SceneController(doc:d)
        d.isolateSelection = true;ctrl.zoomExtents();XCTAssertEqual(ctrl.target,a.center)
        d.isolateSelection = false;d.setPartsHidden([b.id],hidden:true)
        ctrl.zoomExtents();XCTAssertEqual(ctrl.target,a.center)
        WorkspaceAction.showAll.run(doc:d,ctrl:ctrl);ctrl.zoomExtents();XCTAssertGreaterThan(ctrl.target.x,100)
    }
    func testCommandSearchAndViewActionsDoNotDirtyProject() {
        let d = document(),p = board();d.add(p)
        XCTAssertTrue(WorkspaceAction.matching("cnc").contains(.cnc))
        d.showPartsSidebar = false;let token = d.focusPartSearch
        WorkspaceAction.findPart.run(doc:d,ctrl:nil)
        XCTAssertTrue(d.showPartsSidebar);XCTAssertNotEqual(d.focusPartSearch,token)
        XCTAssertEqual(WorkspaceAction.matching("zoom selection"),[.fitSelection])
        XCTAssertTrue(WorkspaceAction.matching("no matching command here").isEmpty)
        let before = d.project
        WorkspaceAction.inspect.run(doc:d,ctrl:nil);WorkspaceAction.history.run(doc:d,ctrl:nil);WorkspaceAction.toggleInspector.run(doc:d,ctrl:nil)
        XCTAssertEqual(d.project,before)
    }
    func testPartSearchMatchesWordsAcrossMetadataAndIgnoresExtraSpaces() {
        var p = board("Left shelf");p.group = "Garage/Upper cabinet";p.shopNumber = 42
        XCTAssertTrue(PartSearch.matches("  shelf  garage plywood  ",part:p))
        XCTAssertTrue(PartSearch.matches("P042 left",part:p))
        XCTAssertTrue(PartSearch.matches("",part:p))
        XCTAssertFalse(PartSearch.matches("shelf walnut",part:p))
        XCTAssertTrue(PartSearch.matches("SIDE  plywood",in:"P012 Side Plywood"))
    }
    func testCommandKeyboardNavigationSkipsUnavailableActionsAndClampsAtEnds() {
        let d = document()
        let actions: [WorkspaceAction] = [.rename,.addStock,.delete,.parameters,.cnc]
        XCTAssertEqual(CommandNavigation.next(in:actions,from:nil,step:1,doc:d),.addStock)
        XCTAssertEqual(CommandNavigation.next(in:actions,from:.addStock,step:1,doc:d),.parameters)
        XCTAssertEqual(CommandNavigation.next(in:actions,from:.parameters,step:1,doc:d),.parameters)
        XCTAssertEqual(CommandNavigation.next(in:actions,from:.addStock,step:-1,doc:d),.addStock)
        XCTAssertNil(CommandNavigation.next(in:[.delete,.rename],from:nil,step:1,doc:d))
        d.add(board());d.select(d.parts[0].id)
        XCTAssertEqual(CommandNavigation.next(in:actions,from:.addStock,step:1,doc:d),.delete)
        d.historyInspection = HistoryInspection(part:d.parts[0].id,through:0)
        XCTAssertEqual(CommandNavigation.next(in:actions,from:.addStock,step:1,doc:d),.parameters)
    }
    func testWorkspaceInspectorAndPaletteFitAtUsableSizes() throws {
        _ = NSApplication.shared
        let d = document()
        if let input = ProcessInfo.processInfo.environment["WOODSHOP_PROJECT_INPUT"] {
            d.restore(try Document.decodeProject(Data(contentsOf:URL(fileURLWithPath:input))))
        } else { d.insertExample() }
        d.select(d.parts[0].id)
        let ctrl = SceneController(doc:d)
        func check<V: View>(_ root: V,width: CGFloat,height: CGFloat,name: String) throws {
            let host = NSHostingView(rootView:root);host.frame = CGRect(x:0,y:0,width:width,height:height)
            let window = NSWindow(contentRect:host.bounds,styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = host
            defer { window.contentView = nil;window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until:Date().addingTimeInterval(0.03))
            XCTAssertLessThanOrEqual(host.fittingSize.width,width+1,name)
            XCTAssertLessThanOrEqual(host.fittingSize.height,height+1,name)
            if let folder = ProcessInfo.processInfo.environment["WOODSHOP_UI_PREVIEW_DIR"],let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+".png"))
            }
        }
        try check(ContentView(doc:d,ctrl:ctrl),width:1440,height:900,name:"workspace")
        for page in InspectorPage.allCases { d.inspectorPage = page;try check(Inspector(doc:d),width:320,height:780,name:"inspector-"+page.rawValue) }
        d.inspectorPage = .machining;d.selectedFace = FaceRef(part:d.parts[0].id,axis:d.parts[0].materialAxes.t,positive:true)
        try check(Inspector(doc:d),width:320,height:780,name:"inspector-face")
        try check(WorkspaceCommandPalette(doc:d,ctrl:ctrl),width:650,height:480,name:"commands")
        try check(ProjectPresetSheet(doc:d,ctrl:ctrl),width:640,height:490,name:"project-presets")
        try check(MachiningRecipesSheet(doc:d),width:650,height:510,name:"machining-recipes")
        try check(DimensionEditorSheet(doc:d,request:DimensionRequest(part:d.parts[0].id,axis:0)),width:510,height:340,name:"dimension-editor")
        try check(ReliefRecipeSheet(doc:d),width:520,height:330,name:"relief-recipe")
        for page in FabricationPage.allCases {
            d.fabricationTab = page.rawValue
            try check(CutListView(doc:d),width:1060,height:790,name:"fabrication-\(page.rawValue)")
        }
        let empty = document()
        try check(CutListView(doc:empty),width:1060,height:790,name:"fabrication-empty")
        d.showInspector = false;d.showPartsSidebar = false
        try check(ContentView(doc:d,ctrl:ctrl),width:1000,height:720,name:"focus-workspace")
    }
}
