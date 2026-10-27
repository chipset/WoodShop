import XCTest
import PDFKit
import SwiftUI
@testable import WoodShop

final class EaseWorkflowTests: XCTestCase {
    func document() -> WoodShop.Document {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Document(startRecoveryTimer:false,recoveryLocation:folder.appendingPathComponent("recovery"),setupStoreURL:folder.appendingPathComponent("setups.json"))
    }
    func board() -> Part {
        var p = Part(name:"Door",origin:.zero,size:SIMD3(18,30,0.75),species:.plywood);p.thicknessAxis = 2;p.grainDirection = 1;return p
    }
    func testDimensionPreviewIsAtomicPropagatesLinksAndSupportsUndo() throws {
        let d = document();var a = board(),b = board();a.name = "A";b.name = "B";d.add(a);d.add(b)
        d.addLink(DimensionLink(source:a.id,sourceAxis:0,target:b.id,targetAxis:0,offset:0))
        let before = d.project,request = DimensionRequest(part:a.id,axis:0)
        let preview = try DimensionChange.preview(before,request:request,text:"24 1/2\"")
        XCTAssertEqual(d.project,before);XCTAssertEqual(preview.affected.count,2)
        XCTAssertEqual(preview.project?.parts.first { $0.id == b.id }?.size.x,24.5)
        d.parameterPreview = preview.project;XCTAssertTrue(d.applyDimensionPreview(preview));XCTAssertNil(d.parameterPreview)
        XCTAssertEqual(d.part(a.id)?.size.x,24.5);d.undo();XCTAssertEqual(d.parts,before.parts)
        XCTAssertThrowsError(try DimensionChange.preview(before,request:DimensionRequest(part:b.id,axis:0),text:"23in"))
        XCTAssertThrowsError(try DimensionChange.preview(before,request:request,text:"zero"))
        XCTAssertThrowsError(try DimensionChange.preview(before,request:request,text:"-1in"))
        d.edit(a.id) { $0.name = "Changed" };let changed = d.project
        XCTAssertFalse(d.applyDimensionPreview(preview));XCTAssertEqual(d.project,changed)
    }
    func testDrivenDimensionEditsItsParameterAndRegeneratesAssembly() throws {
        let d = document();XCTAssertTrue(d.insertPreset(.cabinet,dimensions:PresetDimensions()),d.status)
        let p = try XCTUnwrap(d.parts.first { $0.name == "Left side" })
        let report = try DimensionChange.preview(d.project,request:DimensionRequest(part:p.id,axis:1),text:"900 mm")
        XCTAssertTrue(report.canApply);XCTAssertGreaterThan(report.affected.count,1)
        XCTAssertTrue(d.applyDimensionPreview(report),d.status)
        XCTAssertEqual(d.part(p.id)!.size.y,900/25.4,accuracy:1e-8)
        let right = try XCTUnwrap(d.parts.first { $0.name == "Right side" });XCTAssertEqual(right.size.y,900/25.4,accuracy:1e-8)
        let top = try XCTUnwrap(d.parts.first { $0.name == "Top" })
        XCTAssertThrowsError(try DimensionChange.preview(d.project,request:DimensionRequest(part:top.id,axis:0),text:"25in"))
    }
    func testEveryPresetIsValidAndIndependentWhenInsertedTwice() throws {
        for kind in WoodworkingPreset.allCases {
            let d = document();let dims = PresetDimensions()
            XCTAssertTrue(d.insertPreset(kind,dimensions:dims),d.status);let originals = d.parts
            XCTAssertTrue(d.insertPreset(kind,dimensions:dims),d.status)
            XCTAssertEqual(d.parts.count,originals.count*2)
            XCTAssertEqual(Set(d.studio.parameters!.map(\.name)).count,d.studio.parameters!.count)
            var parameters = d.studio.parameters!
            let index = try XCTUnwrap(parameters.firstIndex { $0.name.hasSuffix("_width") })
            parameters[index].expression = "40in"
            XCTAssertTrue(d.setParameters(parameters),d.status)
            XCTAssertEqual(Array(d.parts.suffix(originals.count)).map(\.size),originals.map(\.size))
            try ModelValidation.validate(d.project)
        }
        var invalid = PresetDimensions();invalid.width = 1
        XCTAssertThrowsError(try PresetBuilder.build(.cabinet,dimensions:invalid,prefix:"bad",group:"Bad"))
    }
    func testMachiningRecipesGenerateEditableValidPatterns() throws {
        let p = board()
        for recipe in [MachiningRecipe.shelfPins,.hingeCups] {
            let pattern = recipe.pattern(part:p,face:nil),operations = try pattern.generated(size:p.size)
            XCTAssertGreaterThan(operations.count,1)
            for op in operations { XCTAssertNil(op.validation(size:p.size)) }
            let d = document();d.add(p);XCTAssertTrue(d.savePattern(pattern,partID:p.id),d.status)
            XCTAssertEqual(d.part(p.id)?.patterns?.first?.id,pattern.id)
        }
        let pattern = MachiningRecipe.shelfPins.pattern(part:p,face:FaceRef(part:p.id,axis:0,positive:false))
        XCTAssertEqual(pattern.axis,0);XCTAssertFalse(pattern.positive)
    }
    func testReliefPreviewAndSuppressionAreUndoable() throws {
        let d = document();var p = board()
        p.cuts = [Cut(kind:"Pocket",lo:SIMD3(2,2,0.25),hi:SIMD3(4,5,0.75),faceAxis:2,facePositive:true,runAxis:1)]
        d.add(p);let before = d.project
        let report = try ReliefRecipe.preview(before,partID:p.id,style:.dogbone,diameter:0.25)
        XCTAssertNil(d.part(p.id)?.cuts[0].relief)
        XCTAssertTrue(d.applyDimensionPreview(report,historyTitle:"Add relief"))
        XCTAssertEqual(d.part(p.id)?.cuts[0].relief?.style,.dogbone)
        let ref = FeatureRef(part:p.id,kind:.cut,feature:p.cuts[0].id)
        XCTAssertTrue(d.setFeatureSuppressed(ref,true),d.status);XCTAssertTrue(d.part(p.id)!.featureSuppressed(FeatureStep(kind:.cut,feature:ref.feature)))
        d.undo();XCTAssertFalse(d.part(p.id)!.featureSuppressed(FeatureStep(kind:.cut,feature:ref.feature)))
        d.historyInspection = HistoryInspection(part:p.id,through:0);XCTAssertFalse(d.setFeatureSuppressed(ref,true))
        var empty = before;empty.parts[0].cuts = []
        XCTAssertThrowsError(try ReliefRecipe.preview(empty,partID:p.id,style:.dogbone,diameter:0.25))
    }
    func testScopedCNCExportPreservesSelectedGeometryAndDetachesExcludedMates() throws {
        let full = try GarageCabinets.project()
        let joint = try XCTUnwrap(full.studio?.matingJoints?.first)
        let scoped = CNCJobScope.project(full,ids:[joint.receiver])
        XCTAssertEqual(scoped.parts.count,1);XCTAssertTrue(scoped.parts[0].cuts.allSatisfy { $0.mateID == nil })
        XCTAssertTrue(scoped.studio?.matingJoints?.isEmpty == true)
        XCTAssertEqual(scoped.parts[0].cuts.map(\.lo),full.parts.first { $0.id == joint.receiver }!.cuts.map(\.lo))
        try ModelValidation.validate(scoped)
        let artifacts = try VCarveExport.artifacts(project:scoped)
        let csv = try XCTUnwrap(artifacts.first { $0.name == "Cut list.csv" })
        XCTAssertTrue(String(decoding:csv.data,as:UTF8.self).contains(scoped.parts[0].name))
        XCTAssertTrue(CNCJobScope.project(full,ids:[]).parts.isEmpty)
    }
    func testReliefRecipeUpdatesSharedComponentsAndPreservesInstancePlacement() throws {
        let d = document();var p = board();p.component = UUID()
        p.cuts = [Cut(kind:"Pocket",lo:SIMD3(2,2,0.25),hi:SIMD3(4,5,0.75),faceAxis:2,facePositive:true,runAxis:1)]
        var instance = p;instance.id = UUID();instance.name = "Second door";instance.origin.x = 40
        d.add(p);d.add(instance)
        let report = try ReliefRecipe.preview(d.project,partID:p.id,style:.dogbone,diameter:0.25)
        XCTAssertEqual(report.affected.count,2);XCTAssertTrue(d.applyDimensionPreview(report))
        XCTAssertEqual(d.part(instance.id)?.origin,instance.origin);XCTAssertEqual(d.part(instance.id)?.name,instance.name)
        XCTAssertEqual(d.part(instance.id)?.cuts[0].relief?.style,.dogbone)
        d.undo();XCTAssertNil(d.part(instance.id)?.cuts[0].relief)
    }
    func testPreflightRequiresPartsCutterAndStockFit() throws {
        let d = document();XCTAssertFalse(CNCPreflight(project:d.project).canExport)
        d.add(board());XCTAssertFalse(CNCPreflight(project:d.project).canExport)
        XCTAssertTrue(d.activateSetup(CNCSetupProfile()),d.status);XCTAssertTrue(CNCPreflight(project:d.project).canExport)
        var oversized = d.project;oversized.sheetLength = 5;oversized.sheetWidth = 5
        let report = CNCPreflight(project:oversized);XCTAssertFalse(report.canExport);XCTAssertTrue(report.errors.contains { $0.contains("exceed") })
    }
    func testEachMachiningDXFHasMatchingVisualSetupPDF() throws {
        _ = NSApplication.shared
        let d = document();var p = board()
        p.operations = try JoineryTools.holes(part:p,axis:2,positive:false,centers:[SIMD2(4,4)],diameter:0.25,depth:0.25)
        p.operations! += try JoineryTools.holes(part:p,axis:0,positive:true,centers:[SIMD2(4,0.375)],diameter:0.25,depth:0.5)
        d.add(p);let files = try VCarveExport.artifacts(project:d.project)
        for vector in files.filter({ $0.name.hasSuffix(".dxf") }) {
            let setup = try XCTUnwrap(files.first { $0.name == String(vector.name.dropLast(4))+" - Setup.pdf" })
            let pdf = try XCTUnwrap(PDFDocument(data:setup.data));XCTAssertEqual(pdf.pageCount,1)
            let text = try XCTUnwrap(pdf.string);XCTAssertTrue(text.contains("X0 Y0"));XCTAssertTrue(text.contains("inches"))
            if vector.name.contains("BOTTOM") { XCTAssertTrue(text.contains("already mirrored")) }
            if vector.name.contains("SIDE") { XCTAssertTrue(text.contains("SIDE fixture")) }
            if vector.name.hasSuffix("TOP.dxf"),let folder = ProcessInfo.processInfo.environment["WOODSHOP_UI_PREVIEW_DIR"] {
                try setup.data.write(to:URL(fileURLWithPath:folder).appendingPathComponent("vcarve-setup.pdf"))
            }
        }
        XCTAssertTrue(files.contains { $0.name == "START HERE - Import files.txt" })
    }
    func testWorkspacePreferencesRoundTripWithoutDirtyingProject() throws {
        let suite = "WoodShopTests."+UUID().uuidString,defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = WorkspacePreferencesStore(defaults:defaults)
        let d = Document(startRecoveryTimer:false,workspaceStore:store);let before = d.project
        d.showInspector = false;d.showPartsSidebar = false;d.showEditableDimensions = false;d.partSearch = "shelf";d.partFilter = "Parts";d.persistWorkspace()
        let controller = SceneController(doc:d);controller.target = SIMD3(22,33,44);controller.distance = 140;controller.ortho = true;controller.updateCamera()
        RunLoop.main.run(until:Date().addingTimeInterval(0.4))
        XCTAssertEqual(d.project,before)
        let next = Document(startRecoveryTimer:false,workspaceStore:store)
        XCTAssertFalse(next.showInspector);XCTAssertFalse(next.showPartsSidebar);XCTAssertFalse(next.showEditableDimensions);XCTAssertEqual(next.partSearch,"shelf")
        let nextController = SceneController(doc:next);XCTAssertEqual(nextController.target,controller.target);XCTAssertEqual(nextController.distance,140);XCTAssertTrue(nextController.ortho)
        let center = try XCTUnwrap(nextController.screenPoint(nextController.target,size:CGSize(width:800,height:600)))
        XCTAssertEqual(center.x,400,accuracy:1e-8);XCTAssertEqual(center.y,300,accuracy:1e-8)
        var profile = CNCSetupProfile();profile.name = "Unsaved active setup"
        XCTAssertTrue(d.activateSetup(profile));d.persistWorkspace()
        let restored = Document(startRecoveryTimer:false,workspaceStore:store)
        XCTAssertEqual(restored.studio.setupProfile?.name,profile.name)
        defaults.set(Data("bad".utf8),forKey:"WoodShop.workspace.v1");XCTAssertEqual(store.load(),WorkspacePreferences())
    }
    func testDimensionProjectionMatchesViewportAndOverlapMenuSelectsBehindPart() throws {
        _ = NSApplication.shared
        let d = document(),front = board();var back = board();back.name = "Behind";back.origin.z = -2
        d.add(front);d.add(back);d.select(front.id)
        let ctrl = SceneController(doc:d);ctrl.target = front.center;ctrl.distance = 90;ctrl.yaw = 0;ctrl.pitch = 0;ctrl.updateCamera()
        let view = ModelView(frame:CGRect(x:0,y:0,width:800,height:600));view.doc = d;view.ctrl = ctrl;view.scene = ctrl.scene;view.pointOfView = ctrl.cameraNode;ctrl.viewport = view
        RunLoop.main.run(until:Date().addingTimeInterval(0.03))
        for world in [front.center,front.origin,front.toWorld(front.size)] {
            let projected = view.projectPoint(vec(world)),overlay = try XCTUnwrap(ctrl.screenPoint(world,size:view.bounds.size))
            XCTAssertEqual(overlay.x,Double(projected.x),accuracy:1);XCTAssertEqual(overlay.y,600-Double(projected.y),accuracy:1)
        }
        let center = view.projectPoint(vec(front.center)),point = CGPoint(x:Double(center.x),y:Double(center.y))
        XCTAssertEqual(Set(view.overlappingParts(at:point)),Set([front.id,back.id]))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseUp,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        let menu = try XCTUnwrap(view.menu(for:event)),submenu = try XCTUnwrap(menu.items.first { $0.title == "Select Overlapping Part" }?.submenu)
        let index = try XCTUnwrap(submenu.items.firstIndex { $0.title.contains("Behind") });submenu.performActionForItem(at:index)
        XCTAssertEqual(d.selection,back.id)
    }
}
