import XCTest
import simd
import PDFKit
import SwiftUI
import SceneKit
@testable import WoodShop

final class CNCWorkflowTests: XCTestCase {
    func board() -> Part {
        var p = Part(name:"Shelf",origin:SIMD3(0.75,5,0),size:SIMD3(20,0.75,10),species:.plywood)
        p.thicknessAxis = 1; p.grainDirection = 0; return p
    }
    func document() -> WoodShop.Document {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Document(startRecoveryTimer:false,recoveryLocation:folder.appendingPathComponent("recovery"),setupStoreURL:folder.appendingPathComponent("setups.json"))
    }
    func volume(_ polys: [Geo.Poly]) -> Double {
        var result = 0.0
        for p in polys where p.pts.count >= 3 { for i in 1..<(p.pts.count-1) { result += simd_dot(p.pts[0],simd_cross(p.pts[i],p.pts[i+1]))/6 } }
        return result
    }
    func pattern() -> DrillingPattern {
        var p = DrillingPattern(); p.columns = 5; p.pitch = SIMD2(1,2); return p
    }
    func receiver(_ name: String = "Left") -> Part {
        var p = Part(name:name,origin:.zero,size:SIMD3(0.75,24,10),species:.plywood)
        p.thicknessAxis = 0; p.grainDirection = 1; return p
    }
    func testPatternStableHoleIDsAndResizeBetweenMargins() throws {
        var recipe = pattern(); recipe.spanU = true
        let first = try recipe.generated(size:board().size)
        recipe.columns = 7
        let expanded = try recipe.generated(size:board().size)
        XCTAssertEqual(Array(expanded.prefix(5)).map(\.id),first.map(\.id))
        XCTAssertEqual(Set(expanded.map(\.id)).count,7)
        let wide = try recipe.generated(size:SIMD3(20,0.75,14))
        XCTAssertEqual(wide.last!.contour.map(\.x).max()!,13.125,accuracy:1e-6)
        XCTAssertEqual(wide.first!.patternID,recipe.id)
    }
    func testPatternExpressionsThroughAndRoundTrip() throws {
        var p = board(),recipe = pattern(); recipe.through = true
        recipe.expressions = [PatternExpression(field:.columns,expression:"holes"),PatternExpression(field:.diameter,expression:"6mm")]
        var project = Project(); project.parts = [p]; project.studio = StudioState()
        project.studio!.parameters = [DesignParameter(name:"holes",expression:"7",kind:.scalar)]
        p.patterns = [recipe]; project.parts = [p]
        try Regeneration.rebuild(parts:&project.parts,links:[],studio:project.studio!)
        let ops = project.parts[0].machiningOperations
        XCTAssertEqual(ops.count,7); XCTAssertEqual(ops[0].depth,0.75)
        XCTAssertEqual(ops[0].contour.map(\.x).max()!-ops[0].contour.map(\.x).min()!,6/25.4,accuracy:1e-7)
        XCTAssertEqual(try Document.decodeProject(JSONEncoder().encode(project)),project)
    }
    func testPatternInvalidEditRollsBackAndSharedInstancesUpdate() throws {
        let d = document(),p = board(); d.add(p); d.makeComponents(); d.duplicateSelected()
        let copy = try XCTUnwrap(d.selectedPart),copyNumber = copy.shopNumber
        var recipe = pattern(); XCTAssertTrue(d.savePattern(recipe,partID:p.id),d.status)
        XCTAssertEqual(d.part(copy.id)?.patterns?.first?.id,recipe.id)
        XCTAssertEqual(d.part(copy.id)?.shopNumber,copyNumber)
        let before = d.designSnapshot
        recipe.columns = 101; XCTAssertFalse(d.savePattern(recipe,partID:p.id))
        XCTAssertEqual(d.designSnapshot,before)
        d.edit(p.id) { $0.name = "Changed" }
        XCTAssertEqual(d.part(copy.id)?.shopNumber,copyNumber)
    }
    func testLinkedMatingDadoFollowsThicknessAndPlacement() throws {
        let d = document(),shelf = board(),side = receiver(); d.add(side); d.add(shelf)
        let joint = MatingJoint(shelf:shelf.id,receiver:side.id,axis:0,positive:true,autoSeat:false)
        XCTAssertTrue(d.createMatingJoint(joint),d.status)
        let cut = try XCTUnwrap(d.part(side.id)?.cuts.first)
        XCTAssertEqual(cut.hi.y-cut.lo.y,0.75,accuracy:1e-8)
        d.edit(shelf.id) { $0.origin.y = 7; $0.size.y = 0.875 }
        let moved = try XCTUnwrap(d.part(side.id)?.cuts.first)
        XCTAssertEqual(moved.id,cut.id); XCTAssertEqual(moved.lo.y,7,accuracy:1e-8)
        XCTAssertEqual(moved.hi.y-moved.lo.y,0.875,accuracy:1e-8)
        XCTAssertNoThrow(try ModelValidation.validate(d.project))
        d.undo(); XCTAssertEqual(d.part(side.id)?.cuts.first?.lo.y,5)
    }
    func testAutomaticSeatBothEndsAndIdempotentRebuild() throws {
        var shelf = board(),left = receiver(),right = receiver("Right"); right.origin.x = 20.75
        let joints = [MatingJoint(shelf:shelf.id,receiver:left.id,axis:0,positive:true),MatingJoint(shelf:shelf.id,receiver:right.id,axis:0,positive:false)]
        var parts = [left,right,shelf]
        try MatingJoinery.regenerate(parts:&parts,joints:joints)
        shelf = parts[2]; left = parts[0]
        XCTAssertEqual(shelf.origin.x,0.5,accuracy:1e-8)
        XCTAssertEqual(shelf.origin.x+shelf.size.x,21,accuracy:1e-8)
        let before = parts; try MatingJoinery.regenerate(parts:&parts,joints:joints)
        XCTAssertEqual(parts,before); XCTAssertEqual(left.cuts.first?.mateID,joints[0].id)
    }
    func testInvalidMatingAlignmentAndCycleAreRejectedAtomically() {
        let d = document(); var p = board(); p.rot.y = 17
        let side = receiver(); d.add(p); d.add(side); let before = d.designSnapshot
        XCTAssertFalse(d.createMatingJoint(MatingJoint(shelf:p.id,receiver:side.id,axis:0,positive:true)))
        XCTAssertEqual(d.designSnapshot,before)
        var parts = [board(),receiver()]
        let a = MatingJoint(shelf:parts[0].id,receiver:parts[1].id,axis:0,positive:true)
        let b = MatingJoint(shelf:parts[1].id,receiver:parts[0].id,axis:1,positive:true)
        XCTAssertThrowsError(try MatingJoinery.regenerate(parts:&parts,joints:[a,b]))
    }
    func testParameterPreviewIsTransientAndReportsConflicts() throws {
        let d = document(); var p = board(); p.patterns = [pattern()]; d.add(p)
        XCTAssertTrue(d.setParameters([DesignParameter(name:"length",expression:"20in")]))
        d.bind(DesignBinding(target:.size,axis:0,expression:"length"),to:p.id)
        let before = d.project
        let report = d.useParameterPreview([DesignParameter(name:"length",expression:"30in")])
        XCTAssertTrue(report.canApply); XCTAssertTrue(report.affected.contains(p.id)); XCTAssertNotNil(d.parameterPreview)
        XCTAssertEqual(d.project,before); XCTAssertFalse(d.prepareForExport())
        d.clearParameterPreview(); XCTAssertNil(d.parameterPreview); XCTAssertEqual(d.project,before)
        let invalid = d.useParameterPreview([DesignParameter(name:"length",expression:"0.5in")])
        XCTAssertFalse(invalid.canApply); XCTAssertTrue(invalid.conflicts.contains { $0.part == p.id })
        XCTAssertEqual(d.project,before)
    }
    func testReplayRollBackOwnershipAndEarlierSourceEdit() throws {
        let d = document(); var p = board(); let recipe = pattern(); p.patterns = [recipe]; p.featureOrder = p.featureSteps
        d.add(p)
        let blank = FeatureReplay.polygons(p,through:0),full = FeatureReplay.polygons(p)
        XCTAssertEqual(volume(blank),150,accuracy:1e-7); XCTAssertLessThan(volume(full),volume(blank))
        let surface = try XCTUnwrap(full.first { $0.source == recipe.id })
        XCTAssertEqual(FeaturePicking.onSurface(part:p,polygon:surface,point:surface.pts[0])?.feature,recipe.id)
        d.edit(p.id) { $0.size.x = 24 }
        XCTAssertEqual(d.part(p.id)?.patterns?.first?.id,recipe.id)
        XCTAssertGreaterThan(volume(Geo.polys(for:d.part(p.id)!)),volume(full))
        d.historyInspection = HistoryInspection(part:p.id,through:0)
        XCTAssertFalse(d.prepareForExport()); d.resumeFeatureHistory(); XCTAssertTrue(d.prepareForExport())
    }
    func testSheetPickingReturnsPatternRecipe() throws {
        var p = board(); p.patterns = [pattern()]
        let flat = Flatten.flat(p),placed = Placed(part:flat,x:3,y:4,sheet:0,group:"")
        let feature = try XCTUnwrap(flat.features.first),center = (feature.rect.lo+feature.rect.hi)/2+SIMD2(3,4)
        XCTAssertEqual(FeaturePicking.inLayout(point:center,placed:[placed],setup:.top,threshold:0.01)?.feature,p.patterns![0].id)
        XCTAssertNil(FeaturePicking.inLayout(point:center,placed:[placed],setup:.bottom,threshold:0.01))
    }
    func testSetupPersistsAcrossDocumentsAndAppliesMeasuredStock() throws {
        let d = document(); var setup = CNCSetupProfile(); setup.measuredThickness = 18/25.4; setup.vcarveTemplate = "18 mm plywood"
        XCTAssertTrue(d.saveSetup(setup),d.status)
        let other = Document(startRecoveryTimer:false,setupStoreURL:d.setupProfileStore.url)
        XCTAssertEqual(other.setupProfiles,[setup]); XCTAssertTrue(other.activateSetup(setup))
        let p = board(); other.add(p); other.applyMeasuredThickness()
        XCTAssertEqual(other.part(p.id)!.size.y,18/25.4,accuracy:1e-7)
        XCTAssertEqual(other.studio.setupProfile?.vcarveTemplate,"18 mm plywood")
    }
    func testReviewReachMismatchWallsAndOverlaps() throws {
        var p = board(),recipe = pattern(),project = Project(),setup = CNCSetupProfile()
        recipe.margin = SIMD2(0.2,1); recipe.pitch.x = 0.1; p.patterns = [recipe]
        setup.tools[0].diameter = 0.5; setup.tools[0].fluteLength = 0.25
        p.toolAssignments = [recipe.id.uuidString:setup.tools[0].id]
        project.parts = [p]; project.studio = StudioState(); project.studio!.setupProfile = setup
        let issues = MachiningReview.issues(project:project)
        XCTAssertTrue(issues.contains { $0.code == "reach" && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.code == "narrow" && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.code == "thin-wall" })
        XCTAssertTrue(issues.contains { $0.code.hasPrefix("overlap-") })
        XCTAssertThrowsError(try VCarveExport.artifacts(project:project))
    }
    func testReplayRefillingMachiningBlocksFlatExport() throws {
        var p = board()
        let pocket = Cut(kind:"Mortise",lo:SIMD3(2,0.25,2),hi:SIMD3(4,0.75,4),faceAxis:1,facePositive:true)
        let fill = Cut(kind:"Tenon",lo:SIMD3(2,0.25,2),hi:SIMD3(3,0.75,4))
        p.cuts = [pocket,fill]; p.featureOrder = p.featureSteps
        var project = Project(); project.parts = [p]
        XCTAssertTrue(MachiningReview.issues(project:project).contains { $0.code.hasPrefix("refilled-") && $0.severity == .error })
        XCTAssertThrowsError(try VCarveExport.artifacts(project:project))
        p.featureOrder = p.featureSteps.reversed(); project.parts = [p]
        XCTAssertFalse(MachiningReview.issues(project:project).contains { $0.code.hasPrefix("refilled-") })
        XCTAssertLessThan(volume(Geo.polys(for:p)),volume(FeatureReplay.polygons(project.parts[0],through:1)))
    }
    func testPartLabelsDocumentsAndBundleAgree() throws {
        let d = document(),p = board(); d.add(p)
        let number = try XCTUnwrap(d.part(p.id)?.shopNumber),label = ShopIdentity.label(d.part(p.id)!)
        d.edit(p.id) { $0.name = "Renamed shelf" }; XCTAssertEqual(d.part(p.id)?.shopNumber,number)
        let bundle = try VCarveExport.artifacts(project:d.project)
        let labels = try XCTUnwrap(bundle.first { $0.name == "Part labels.pdf" })
        XCTAssertTrue(PDFDocument(data:labels.data)?.string?.contains(label) == true)
        let guide = try XCTUnwrap(bundle.first { $0.name == "Assembly guide.pdf" })
        XCTAssertGreaterThan(PDFDocument(data:guide.data)?.pageCount ?? 0,0)
        XCTAssertTrue(CutList.csv(CutList.rows(d.parts),metric:false).contains(label))
        XCTAssertTrue(bundle.contains { $0.name.hasSuffix(".svg") && String(data:$0.data,encoding:.utf8)?.contains(label) == true })
        d.duplicateSelected(); XCTAssertNotEqual(d.selectedPart?.shopNumber,number)
        XCTAssertEqual(try Document.decodeProject(JSONEncoder().encode(d.project)),d.project)
    }
    func testLegacyVersionsRemainReadable() throws {
        for version in 1...3 {
            var p = Project(); p.version = version; p.parts = [board()]
            XCTAssertEqual(try Document.decodeProject(JSONEncoder().encode(p)).parts.count,1)
        }
    }
    func testNewEditorsFitAndPatternProxiesExist() throws {
        _ = NSApplication.shared
        let d = document(); var p = board(); p.patterns = [pattern()]; d.add(p); let ctrl = SceneController(doc:d)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        let partNode = try XCTUnwrap(ctrl.scene.rootNode.childNode(withName:p.id.uuidString,recursively:true))
        var proxies = 0
        partNode.enumerateChildNodes { node,_ in if node.categoryBitMask == 4 { proxies += 1 } }
        XCTAssertGreaterThan(proxies,0)
        let views: [AnyView] = [AnyView(PatternEditor(doc:d,partID:p.id,initial:p.patterns![0])),AnyView(MatingJointWizard(doc:d)),AnyView(SetupProfilesPanel(doc:d)),AnyView(MachiningReviewPanel(doc:d)),AnyView(AssemblyStepsEditor(doc:d))]
        for view in views {
            let host = NSHostingView(rootView:view); host.frame = CGRect(x:0,y:0,width:1000,height:800); host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width,1001)
        }
    }
    func testCopiedAssemblyHasIndependentMatingLinksAndDeletionCleansThem() throws {
        let d = document(),shelf = board(),side = receiver(); d.add(side); d.add(shelf)
        XCTAssertTrue(d.createMatingJoint(MatingJoint(shelf:shelf.id,receiver:side.id,axis:0,positive:true,autoSeat:false)))
        d.select(side.id); d.select(shelf.id,extending:true); d.duplicateSelected()
        XCTAssertEqual(d.studio.matingJoints?.count,2)
        let clone = try XCTUnwrap(d.studio.matingJoints?.last)
        XCTAssertNotEqual(clone.shelf,shelf.id); XCTAssertNotEqual(clone.receiver,side.id)
        XCTAssertEqual(d.part(clone.receiver)?.cuts.first?.id,clone.cutID)
        d.select(clone.shelf); d.deleteSelected()
        XCTAssertEqual(d.studio.matingJoints?.count,1); XCTAssertTrue(d.part(clone.receiver)?.cuts.isEmpty == true)
        XCTAssertNoThrow(try ModelValidation.validate(d.project))
    }
    func testPatternRotationAndReflectionPreserveMachining() throws {
        var part = board(); part.patterns = [pattern()]
        let initial = part.machiningOperations
        let rotated = part.rotated90(axis:1)
        XCTAssertEqual(rotated.machiningOperations.count,initial.count)
        XCTAssertNil(ModelValidation.part(rotated))
        let originalVolume = volume(Geo.polys(for:part))
        XCTAssertEqual(volume(Geo.polys(for:rotated)),originalVolume,accuracy:1e-6)
        var mirrored = part; mirrored.patterns = part.patterns?.map { $0.reflected(axis:0) }
        XCTAssertEqual(volume(Geo.polys(for:mirrored)),originalVolume,accuracy:1e-6)
    }
    func testDoubleClickThroughHoleSelectsItsPatternIn3D() throws {
        _ = NSApplication.shared
        let d = document(); var p = board(),recipe = pattern(); recipe.through = true; p.patterns = [recipe]; d.add(p); d.tool = .select
        let ctrl = SceneController(doc:d); ctrl.target = p.center; ctrl.distance = 35; ctrl.updateCamera()
        let view = ModelView(frame:CGRect(x:0,y:0,width:1000,height:800)); view.doc = d; view.ctrl = ctrl; view.scene = ctrl.scene; view.pointOfView = ctrl.cameraNode
        view.connectActions(); RunLoop.main.run(until:Date().addingTimeInterval(0.04))
        let local = SIMD3<Double>(1,p.size.y,1),point = view.projectPoint(vec(p.toWorld(local)))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:CGPoint(x:CGFloat(point.x),y:CGFloat(point.y)),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:2,pressure:1))
        view.mouseDown(with:click)
        XCTAssertEqual(d.selectedFeature?.feature,recipe.id); XCTAssertTrue(d.showFeatureEditor)
    }

}
