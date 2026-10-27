import XCTest
import SwiftUI
import PDFKit
import simd
@testable import WoodShop

final class FaceSketchTests: XCTestCase {
    func document() -> WoodShop.Document {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Document(startRecoveryTimer:false,recoveryLocation:root.appendingPathComponent("recovery"),setupStoreURL:root.appendingPathComponent("setups"))
    }
    func board() -> Part {
        var p = Part(name:"Curved pocket panel",origin:.zero,size:SIMD3(20,0.75,12),species:.plywood)
        p.thicknessAxis = 1;p.grainDirection = 0;return p
    }
    func operation(_ sketch: FaceSketch,axis: Int = 1,positive: Bool = true) -> MachiningOperation {
        MachiningOperation(name:"Face sketch",axis:axis,positive:positive,depth:0.25,contour:[],sketch:sketch)
    }
    func seed() -> FaceSketch { FaceSketch.seed(part:board(),axis:1) }
    func apply(_ sketch: FaceSketch,to d: WoodShop.Document,part: Part,axis: Int = 1,positive: Bool = true) throws -> UUID {
        let op = operation(sketch,axis:axis,positive:positive)
        let report = try FaceSketchEditing.preview(d.project,partID:part.id,operation:op,values:sketch)
        XCTAssertTrue(d.applyDimensionPreview(report,historyTitle:"Face sketch"),d.status)
        return op.id
    }
    func volume(_ p: Part) -> Double {
        Geo.polys(for:p).reduce(0) { sum,poly in
            sum+(1..<(poly.pts.count-1)).reduce(0) { total,i in total+simd_dot(poly.pts[0],simd_cross(poly.pts[i],poly.pts[i+1]))/6 }
        }
    }
    func testEllipseGeometryMeetsChordToleranceAndArea() throws {
        var s = seed();s.center = SIMD2(6,8);s.size = SIMD2(4,6)
        let face = SIMD2(12.0,20.0),points = try s.contour(faceSize:face)
        XCTAssertTrue(Planar.isSimple(points));XCTAssertLessThanOrEqual(points.count,512)
        XCTAssertEqual(abs(Planar.signedArea(points)),6 * .pi,accuracy:0.02)
        for i in points.indices {
            let a = points[i],b = points[(i+1)%points.count],middle = (a+b)/2
            let radius = simd_length((middle-s.center)/(s.size/2))
            XCTAssertLessThanOrEqual((1-radius)*3,FaceSketch.tolerance+1e-8)
        }
    }
    func testArcGrooveHasRoundCapsAndExplicitWidth() throws {
        var s = seed();s.shape = .arc;s.mode = .groove;s.center = SIMD2(6,10);s.size = SIMD2(6,6);s.grooveWidth = 0.25
        let contour = try s.contour(faceSize:SIMD2(12,20))
        XCTAssertTrue(Planar.isSimple(contour));XCTAssertGreaterThan(Planar.signedArea(contour),0)
        let expected = 3 * .pi*0.25 + .pi*pow(0.125,2)
        XCTAssertEqual(Planar.signedArea(contour),expected,accuracy:0.01)
        let op = try s.generated(from:operation(s),size:board().size,values:[:]);XCTAssertEqual(op.kind,"Groove")
        XCTAssertNil(op.validation(size:board().size))
    }
    func testBezierCurveKeepsHandlesAndRejectsCrossingClosedPaths() throws {
        var s = seed();s.shape = .path;s.mode = .groove;s.closed = false
        s.nodes = [.init(point:SIMD2(0,0),outgoing:SIMD2(0.2,0.8)),.init(point:SIMD2(1,0),incoming:SIMD2(0.8,0.8))]
        let points = try s.path(faceSize:SIMD2(12,20));XCTAssertGreaterThan(points.count,10)
        XCTAssertGreaterThan(points.map(\.y).max()!,s.center.y)
        XCTAssertTrue(Planar.isSimple(try s.contour(faceSize:SIMD2(12,20))))
        s.closed = true;s.mode = .pocket;s.nodes = [.init(point:.zero),.init(point:SIMD2(1,1)),.init(point:SIMD2(0,1)),.init(point:SIMD2(1,0))]
        XCTAssertThrowsError(try s.contour(faceSize:SIMD2(12,20)))
    }
    func testRectanglePocketActuallyRemovesItsVolumeOnBothFaces() throws {
        for positive in [true,false] {
            let d = document(),p = board();d.add(p)
            var s = seed();s.shape = .rectangle;s.size = SIMD2(2,3);s.depth = 0.25
            _ = try apply(s,to:d,part:p,positive:positive)
            XCTAssertEqual(volume(d.part(p.id)!),20*12*0.75-2*3*0.25,accuracy:1e-6)
        }
    }
    func testSketchOnEveryOuterFaceAndRotatedPart() throws {
        for axis in 0..<3 { for positive in [false,true] {
            let d = document();var p = board();p.rot = SIMD3(10,25,35);d.add(p)
            var s = FaceSketch.seed(part:p,axis:axis);s.shape = .rectangle
            _ = try apply(s,to:d,part:p,axis:axis,positive:positive)
            let op = d.part(p.id)!.operations![0]
            XCTAssertEqual(op.axis,axis);XCTAssertEqual(op.positive,positive)
            XCTAssertTrue(op.polygons(size:p.size).allSatisfy { $0.pts.allSatisfy(ModelValidation.finite) })
        } }
    }
    func testThroughCutFollowsThicknessAndKeepsEditableSource() throws {
        let d = document(),p = board();d.add(p)
        var s = seed();s.mode = .through;s.shape = .rectangle;s.size = SIMD2(2,3)
        let id = try apply(s,to:d,part:p)
        XCTAssertEqual(d.part(p.id)?.operations?[0].depth,0.75)
        d.edit(p.id) { $0.size.y = 1.25 }
        XCTAssertEqual(d.part(p.id)?.operations?[0].depth,1.25)
        XCTAssertEqual(d.part(p.id)?.operations?[0].sketch,s)
        XCTAssertEqual(d.part(p.id)?.operations?[0].id,id)
        XCTAssertEqual(volume(d.part(p.id)!),20*12*1.25-2*3*1.25,accuracy:1e-6)
    }
    func testFixedAndScalingSketchesBehavePredictablyOnResize() throws {
        for scale in [false,true] {
            let d = document(),p = board();d.add(p)
            var s = seed();s.shape = .rectangle;s.scaleWithFace = scale
            _ = try apply(s,to:d,part:p)
            let before = d.part(p.id)!.operations![0].openingBounds
            d.edit(p.id) { $0.resizeJoinery = true;$0.size.x *= 2;$0.size.z *= 2 }
            let after = d.part(p.id)!.operations![0].openingBounds
            XCTAssertEqual(after.center,before.center*(scale ? 2 : 1));XCTAssertEqual(after.span,before.span*(scale ? 2 : 1))
            XCTAssertEqual(d.part(p.id)?.operations?[0].depth,s.depth)
        }
    }
    func testParametersRegenerateSourceAndInvalidChangesRollBack() throws {
        let d = document(),p = board();d.add(p)
        XCTAssertTrue(d.setParameters([DesignParameter(name:"pocket_width",expression:"4in"),DesignParameter(name:"pocket_depth",expression:"0.25in")]))
        var s = seed();s.shape = .rectangle
        s.expressions = [SketchExpression(field:.width,expression:"pocket_width"),SketchExpression(field:.depth,expression:"pocket_depth")]
        let id = try apply(s,to:d,part:p),before = d.project
        var parameters = d.studio.parameters!;parameters[0].expression = "6in"
        XCTAssertTrue(d.setParameters(parameters),d.status)
        XCTAssertEqual(d.part(p.id)?.operations?[0].openingBounds.span.x,6)
        parameters[1].expression = "2in";let valid = d.project
        XCTAssertFalse(d.setParameters(parameters));XCTAssertEqual(d.project,valid)
        d.undo();XCTAssertEqual(d.parts,before.parts)
        XCTAssertEqual(d.part(p.id)?.operations?[0].id,id)
    }
    func testLocalRotationAndReflectionPreserveCurveSourceAndGeometry() throws {
        let d = document(),p = board();d.add(p)
        var s = seed();s.shape = .arc;s.mode = .groove;s.size = SIMD2(3,3);s.sweepAngle = 120
        _ = try apply(s,to:d,part:p)
        let original = d.part(p.id)!
        func keys(_ points: [SIMD2<Double>]) -> Set<String> { Set(points.map { "\(($0.x*1e6).rounded())|\(($0.y*1e6).rounded())" }) }
        for axis in 0..<3 {
            let transformed = original.rotated90(axis:axis),expected = transformed.operations![0].contour
            var parts = [transformed];try Regeneration.rebuild(parts:&parts,links:[],studio:StudioState())
            XCTAssertEqual(keys(parts[0].operations![0].contour),keys(expected));XCTAssertNotNil(parts[0].operations![0].sketch)
            let reflected = original.reflectedLocal(axis:axis),refExpected = reflected.operations![0].contour
            parts = [reflected];try Regeneration.rebuild(parts:&parts,links:[],studio:StudioState())
            XCTAssertEqual(keys(parts[0].operations![0].contour),keys(refExpected))
        }
    }
    func testCurvedPanelBoundaryAndMeshStockAreValidated() throws {
        let d = document();var p = board();p.profile = .preset(.oval,part:p);d.add(p)
        var s = seed();s.shape = .rectangle;s.size = SIMD2(2,2);s.center = SIMD2(1.1,1.1)
        XCTAssertThrowsError(try FaceSketchEditing.preview(d.project,partID:p.id,operation:operation(s),values:s))
        s.center = SIMD2(6,10)
        XCTAssertNoThrow(try FaceSketchEditing.preview(d.project,partID:p.id,operation:operation(s),values:s))
        var meshProject = d.project;meshProject.parts[0].mesh = MeshSolid(faces:[])
        XCTAssertThrowsError(try FaceSketchEditing.preview(meshProject,partID:p.id,operation:operation(s),values:s))
    }
    func testSharedComponentsHistorySuppressionUndoAndRoundTrip() throws {
        let d = document();var p = board();p.component = UUID();var instance = p;instance.id = UUID();instance.origin.x = 30
        d.add(p);d.add(instance);let before = d.project
        var s = seed();s.shape = .rectangle
        let op = operation(s),report = try FaceSketchEditing.preview(before,partID:p.id,operation:op,values:s)
        XCTAssertEqual(d.project,before);XCTAssertEqual(report.affected.count,2)
        XCTAssertTrue(d.applyDimensionPreview(report));XCTAssertEqual(d.part(instance.id)?.origin,instance.origin)
        XCTAssertEqual(d.part(instance.id)?.operations?[0].sketch,s)
        let saved = try Document.decodeProject(JSONEncoder().encode(d.project));XCTAssertEqual(saved,d.project);XCTAssertEqual(saved.version,6)
        let ref = FeatureRef(part:p.id,kind:.operation,feature:op.id)
        XCTAssertTrue(d.setFeatureSuppressed(ref,true));XCTAssertTrue(d.part(instance.id)?.operations?[0].suppressed == true)
        d.undo();XCTAssertFalse(d.part(p.id)?.operations?[0].suppressed == true)
        d.undo();XCTAssertEqual(d.parts,before.parts)
        d.redo();XCTAssertNotNil(d.part(p.id)?.operations?[0].sketch)
    }
    func testVCarveGetsClosedGrooveBoundaryAndCorrectSetupAndDepth() throws {
        _ = NSApplication.shared
        for axis in [1,0] { for positive in [true,false] {
            let d = document(),p = board();d.add(p);d.metric = positive
            var s = FaceSketch.seed(part:p,axis:axis);s.shape = .arc;s.mode = .groove;s.size = SIMD2(repeating:min(p.size[(axis+1)%3],p.size[(axis+2)%3])*0.4)
            if axis == 0 { s.grooveWidth = 0.1 }
            _ = try apply(s,to:d,part:p,axis:axis,positive:positive)
            let files = try VCarveExport.artifacts(project:d.project)
            let expected = axis == 0 ? "SIDE" : (positive ? "TOP" : "BOTTOM")
            let vector = try XCTUnwrap(files.first { $0.name.contains(expected) && $0.name.hasSuffix(".dxf") })
            let text = String(decoding:vector.data,as:UTF8.self)
            XCTAssertTrue(text.contains("POCKET"));XCTAssertTrue(text.contains(d.metric ? "6.35mm" : "0.25in"))
            XCTAssertTrue(text.contains("70\n1\n"),"CNC receives a closed pocket boundary, never an open centerline.")
        } }
    }
    func testGrooveCutterReviewUsesWidthNotOverallBoundingBox() throws {
        let d = document(),p = board();d.add(p)
        var s = seed();s.shape = .arc;s.mode = .groove;s.grooveWidth = 0.125
        _ = try apply(s,to:d,part:p);XCTAssertTrue(d.activateSetup(CNCSetupProfile()))
        XCTAssertTrue(MachiningReview.issues(project:d.project).contains { $0.code == "sketch-groove-tool" && $0.severity == .error })
        XCTAssertThrowsError(try VCarveExport.artifacts(project:d.project))
    }
    func testMalformedAndUnsupportedSketchesFailWithoutChangingDocument() throws {
        let d = document(),p = board();d.add(p);let before = d.project
        var variants: [FaceSketch] = []
        var s = seed();s.depth = 2;variants.append(s)
        s = seed();s.center = SIMD2(-50,-50);variants.append(s)
        s = seed();s.shape = .arc;variants.append(s)
        s = seed();s.size.x = .infinity;variants.append(s)
        s = seed();s.shape = .path;s.closed = true;s.nodes = Array(repeating:.init(point:.zero),count:65);variants.append(s)
        s = seed();s.orientation.x = SIMD2(2,0);variants.append(s)
        for invalid in variants { XCTAssertThrowsError(try FaceSketchEditing.preview(before,partID:p.id,operation:operation(invalid),values:invalid));XCTAssertEqual(d.project,before) }
        XCTAssertThrowsError(try SketchStroke.outline([.zero,SIMD2(1,0)],width:1e300))
        XCTAssertThrowsError(try SketchStroke.outline([.zero,.zero],width:0.25))
    }
    func testSketchCutterAssignmentIsPreviewedSavedAndPreservedOnGeometryEdits() throws {
        let d = document(),p = board();d.add(p)
        var profile = CNCSetupProfile(),small = CuttingTool();small.name = "Small groove mill";small.diameter = 0.0625
        profile.tools.append(small);XCTAssertTrue(d.activateSetup(profile))
        var s = seed();s.shape = .arc;s.mode = .groove;s.grooveWidth = 0.125
        let op = operation(s),preview = try FaceSketchEditing.preview(d.project,partID:p.id,operation:op,values:s,toolID:small.id)
        XCTAssertNil(d.part(p.id)?.toolAssignments)
        XCTAssertTrue(d.applyDimensionPreview(preview));XCTAssertEqual(d.part(p.id)?.toolAssignments?[op.id.uuidString],small.id)
        XCTAssertFalse(MachiningReview.issues(project:d.project).contains { $0.code == "sketch-groove-tool" })
        s.depth = 0.125
        let edited = try FaceSketchEditing.preview(d.project,partID:p.id,operation:d.part(p.id)!.operations![0],values:s)
        XCTAssertEqual(edited.project?.parts[0].toolAssignments?[op.id.uuidString],small.id)
        XCTAssertThrowsError(try FaceSketchEditing.preview(d.project,partID:p.id,operation:op,values:s,toolID:UUID()))
    }
    func testReopeningSketchDoesNotModifyTheProjectAndBlocksExportUntilClosed() throws {
        let d = document(),p = board();d.add(p)
        var s = seed();s.shape = .rectangle;_ = try apply(s,to:d,part:p)
        let before = d.project
        d.faceSketchEditorActive = true
        XCTAssertFalse(WorkspaceAction.delete.enabled(in:d));XCTAssertFalse(d.prepareForExport())
        d.faceSketchEditorActive = false;XCTAssertTrue(d.prepareForExport());XCTAssertEqual(d.project,before)
        let report = try FaceSketchEditing.preview(before,partID:p.id,operation:d.part(p.id)!.operations![0],values:s)
        XCTAssertEqual(report.project?.parts,d.parts)
    }
    func testSketchMenusAndEditorLayouts() throws {
        _ = NSApplication.shared
        let d = document(),p = board();d.add(p);d.select(p.id);d.selectedFace = FaceRef(part:p.id,axis:1,positive:false)
        XCTAssertTrue(WorkspaceAction.matching("bezier curve").contains(.sketchFace))
        WorkspaceAction.sketchFace.run(doc:d,ctrl:nil);XCTAssertEqual(d.faceSketchRequest?.axis,1);XCTAssertFalse(d.faceSketchRequest!.positive)
        let menu = WorkspaceMenus.make(doc:d,ctrl:nil,part:p.id);XCTAssertNotNil(menu.items.first { $0.title == "Sketch on Face…" })
        func check(_ s: FaceSketch,name: String) throws {
            let view = NSHostingView(rootView:FaceSketchEditor(doc:d,partID:p.id,initial:operation(s)))
            let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1060,height:780),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = view;defer { window.contentView = nil;window.close() }
            view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            XCTAssertLessThanOrEqual(view.fittingSize.width,1061);XCTAssertLessThanOrEqual(view.fittingSize.height,781)
            if let folder = ProcessInfo.processInfo.environment["WOODSHOP_UI_PREVIEW_DIR"],let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:rep);try rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+".png"))
            }
        }
        try check(seed(),name:"face-sketch-ellipse")
        var rounded = seed();rounded.shape = .roundedRectangle;rounded.islandInset = 0.25;try check(rounded,name:"face-sketch-rounded-island")
        var slot = seed();slot.shape = .slot;try check(slot,name:"face-sketch-slot")
        var arc = seed();arc.shape = .arc;arc.mode = .groove;try check(arc,name:"face-sketch-arc")
        var path = seed();path.shape = .path;path.mode = .groove;path.nodes = [.init(point:.zero,outgoing:SIMD2(0.2,1)),.init(point:SIMD2(1,0),incoming:SIMD2(0.8,1))]
        try check(path,name:"face-sketch-bezier")
    }
}
