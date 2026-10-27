import XCTest
import AppKit
import SwiftUI
import PDFKit
import simd
@testable import WoodShop

final class EnhancementTests: XCTestCase {
    private func board(_ name: String = "Panel",origin: SIMD3<Double> = .zero,size: SIMD3<Double> = SIMD3(16,0.75,12)) -> Part {
        var p = Part(name:name,origin:origin,size:size,species:.plywood);p.thicknessAxis = 1;p.grainDirection = 0;return p
    }
    private func volume(_ p: Part) -> Double {
        abs(Geo.polys(for:p).reduce(0.0) { total,poly in
            guard poly.pts.count>=3 else { return total }
            return total+(1..<(poly.pts.count-1)).reduce(0.0) { $0+simd_dot(poly.pts[0],simd_cross(poly.pts[$1],poly.pts[$1+1]))/6 }
        })
    }
    private func document() -> WoodShop.Document {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Document(startRecoveryTimer:false,recoveryLocation:root.appendingPathComponent("recovery"),setupStoreURL:root.appendingPathComponent("setups"),hardwareStoreURL:root.appendingPathComponent("hardware"))
    }
    func testRoundedSlotsChamfersAndFilletsCreateEditableMachining() throws {
        let p = board();let face = SIMD2(12.0,16.0)
        for shape in [FaceSketchShape.roundedRectangle,.slot,.chamferedRectangle] {
            var sketch = FaceSketch.seed(part:p,axis:1);sketch.shape = shape;sketch.size = SIMD2(4,3);sketch.cornerSize = 0.4
            let points = try sketch.contour(faceSize:face)
            XCTAssertTrue(Planar.isSimple(points));XCTAssertGreaterThan(Planar.signedArea(points),0)
            XCTAssertLessThan(Planar.signedArea(points),12)
            let source = MachiningOperation(name:shape.rawValue,axis:1,positive:true,depth:0.25,contour:[],sketch:sketch)
            let operation = try sketch.generated(from:source,size:p.size,values:[:])
            XCTAssertEqual(operation.sketch,sketch);XCTAssertNil(operation.validation(size:p.size))
        }
        var path = FaceSketch.seed(part:p,axis:1);path.shape = .path;path.closed = true;path.nodes = [.init(point:.zero),.init(point:SIMD2(1,0)),.init(point:SIMD2(1,1)),.init(point:SIMD2(0,1))]
        let fillet = try SketchCorners.trim(path,index:1,radius:0.25,chamfer:false)
        let chamfer = try SketchCorners.trim(path,index:1,radius:0.25,chamfer:true)
        XCTAssertEqual(fillet.nodes.count,5);XCTAssertNotNil(fillet.nodes[1].outgoing);XCTAssertNil(chamfer.nodes[1].outgoing)
    }
    func testConstraintsAndSnapReferencesAreDeterministic() throws {
        var s = FaceSketch.seed(part:board(),axis:1);s.shape = .path;s.nodes = [.init(point:SIMD2(0,0)),.init(point:SIMD2(0.3,0.2)),.init(point:SIMD2(0.6,0.5))]
        s.constraints = [SketchConstraint(kind:.horizontal,edge:0)]
        let solved = try s.evaluated([:]);XCTAssertEqual(solved.nodes[0].point.y,solved.nodes[1].point.y,accuracy:1e-8)
        s.constraints!.append(SketchConstraint(kind:.perpendicular,edge:1,reference:0))
        let perpendicular = try s.evaluated([:]);let a = perpendicular.nodes[1].point-perpendicular.nodes[0].point,b = perpendicular.nodes[2].point-perpendicular.nodes[1].point
        XCTAssertEqual(simd_dot(a,b),0,accuracy:1e-8)
        s.constraints!.append(SketchConstraint(kind:.vertical,edge:1))
        XCTAssertThrowsError(try s.evaluated([:]))
        let snap = SketchSnapGeometry(part:board(),axis:1)
        XCTAssertEqual(snap.nearest(SIMD2(0.01,0.01),tolerance:0.05)?.label,"Stock vertex")
        XCTAssertEqual(snap.nearest(SIMD2(0.02,4),tolerance:0.05)?.label,"Stock edge")
    }
    func testRegenerationConflictIdentifiesEditableSketch() throws {
        var project = Project(),part = board()
        let parameter = DesignParameter(name:"pocket_width",expression:"2in")
        project.studio = StudioState();project.studio!.parameters = [parameter]
        var sketch = FaceSketch.seed(part:part,axis:1);sketch.shape = .rectangle;sketch.expressions = [SketchExpression(field:.width,expression:"pocket_width")]
        let source = MachiningOperation(name:"Driven pocket",axis:1,positive:true,depth:0.25,contour:[],sketch:sketch)
        let values = try Parametric.values([parameter]);part.operations = [try sketch.generated(from:source,size:part.size,values:values)]
        project.parts = [part]
        let report = Regeneration.preview(project,parameters:[DesignParameter(name:"pocket_width",expression:"40in")])
        XCTAssertNil(report.project);XCTAssertEqual(report.conflicts.first?.feature?.feature,source.id)
        XCTAssertTrue(report.conflicts.first?.message.contains("Driven pocket") == true)
    }
    func testClosedGrooveAndPocketIslandPreserveCoreAndExportAsLoops() throws {
        var p = board();var s = FaceSketch.seed(part:p,axis:1);s.shape = .rectangle;s.mode = .pocket;s.center = SIMD2(4,5);s.size = SIMD2(4,4);s.islandInset = 0.5
        let source = MachiningOperation(name:"Raised center",axis:1,positive:true,depth:0.25,contour:[],sketch:s)
        let op = try s.generated(from:source,size:p.size,values:[:]);p.operations = [op]
        let removed = (abs(Planar.signedArea(op.contour))-abs(Planar.signedArea(op.islands![0])))*op.depth
        XCTAssertEqual(volume(p),16*12*0.75-removed,accuracy:1e-4)
        var groove = s;groove.mode = .groove;groove.islandInset = nil;groove.grooveWidth = 0.25
        let ring = try groove.generated(from:MachiningOperation(name:"Closed groove",axis:1,positive:true,depth:0.25,contour:[],sketch:groove),size:p.size,values:[:])
        XCTAssertEqual(ring.islands?.count,1);XCTAssertGreaterThan(Planar.signedArea(ring.contour),Planar.signedArea(ring.islands![0]))
        var project = Project();project.parts = [p]
        _ = NSApplication.shared
        let files = try VCarveExport.artifacts(project:project)
        let top = try XCTUnwrap(files.first { $0.name.contains("TOP") && $0.name.hasSuffix(".dxf") })
        let audit = try CNCVectorAudit.validate(top.data,metric:false)
        XCTAssertGreaterThanOrEqual(audit.polylines,3);XCTAssertTrue(audit.layers.contains { $0.hasPrefix("POCKET") })
    }
    func testRelationshipsFollowChangedGeometryAndRejectCyclesAtomically() throws {
        let doc = document();let a = board("Reference",size:SIMD3(8,0.75,8)),b = board("Dependent",origin:SIMD3(20,0,0),size:SIMD3(4,0.75,4))
        doc.add(a);doc.add(b)
        let r = AssemblyRelation(source:a.id,target:b.id,axis:0,sourceAnchor:.maximum,targetAnchor:.minimum,offset:0.5)
        XCTAssertTrue(doc.setAssemblyRelation(r),doc.status);XCTAssertEqual(doc.part(b.id)!.origin.x,8.5,accuracy:1e-8)
        doc.edit(a.id) { $0.size.x = 10 };XCTAssertEqual(doc.part(b.id)!.origin.x,10.5,accuracy:1e-8)
        let before = doc.project
        XCTAssertFalse(doc.setAssemblyRelation(AssemblyRelation(source:b.id,target:a.id,axis:0)))
        XCTAssertEqual(doc.project,before)
        XCTAssertFalse(doc.transaction { doc.parts[1].bindings = [DesignBinding(target:.position,axis:0,expression:"10in")] })
        XCTAssertEqual(doc.project,before)
        doc.undo();XCTAssertEqual(doc.part(b.id)!.origin.x,8.5,accuracy:1e-8)
    }
    func testNestingUsesMeasuredOffcutOnceAndPreservesGrain() throws {
        let stock = SheetStock(name:"Offcut A",species:.plywood,thickness:0.75,length:24,width:16,cost:4)
        let parts = [board("A",size:SIMD3(12,0.75,8)),board("B",size:SIMD3(12,0.75,8)),board("C",size:SIMD3(12,0.75,8))]
        let flats = parts.map(Flatten.flat)
        let result = Nesting.nest(flats,sheetL:48,sheetW:24,gap:0.5,stocks:[stock])
        XCTAssertTrue(result.oversize.isEmpty);XCTAssertEqual(result.placed.count,3)
        XCTAssertEqual(result.stockRecords?.values.filter { $0.id == stock.id }.count,1)
        XCTAssertTrue(result.placed.allSatisfy { $0.part.rotationDegrees == 0 })
        for placed in result.placed { let available = try XCTUnwrap(result.stock(at:placed.sheet));XCTAssertLessThanOrEqual(placed.x-result.sheets[placed.sheet].x+placed.part.length,available.length+1e-8);XCTAssertLessThanOrEqual(placed.y+placed.part.width,available.width+1e-8) }
    }
    func testAssemblyCheckUsesMachinedSolidAndReportsRealCollision() throws {
        var panel = board(),plug = board("Plug",origin:SIMD3(4,0,4),size:SIMD3(2,0.75,2))
        var s = FaceSketch.seed(part:panel,axis:1);s.shape = .rectangle;s.mode = .through;s.center = SIMD2(5,5);s.size = SIMD2(4,4)
        let source = MachiningOperation(name:"Through opening",axis:1,positive:true,depth:0.75,contour:[],sketch:s)
        panel.operations = [try s.generated(from:source,size:panel.size,values:[:])]
        var project = Project();project.parts = [panel,plug]
        XCTAssertFalse(AssemblyReview.issues(project).contains { $0.severity == .error })
        plug.origin.x = 0;project.parts[1] = plug
        XCTAssertTrue(AssemblyReview.issues(project).contains { $0.severity == .error })
    }
    func testAnalysisCacheRespondsToInventoryAndGeometryChanges() throws {
        CNCAnalysis.reset()
        var project = Project();project.parts = [board("A",size:SIMD3(12,0.75,8))];project.sheetLength = 24;project.sheetWidth = 24
        let first = CNCAnalysis.layout(project)
        XCTAssertEqual(first.stock(at:0)?.name,"Full sheet")
        var studio = StudioState();studio.useOffcuts = true
        let stock = SheetStock(name:"Saved offcut",species:.plywood,thickness:0.75,length:16,width:12)
        studio.offcuts = [stock];project.studio = studio
        XCTAssertEqual(CNCAnalysis.layout(project).stock(at:0)?.id,stock.id)
        project.parts[0].size.x = 20
        XCTAssertEqual(CNCAnalysis.layout(project).stock(at:0)?.name,"Full sheet")
    }
    func testHardwareCostBandingAndStoreRoundTrip() throws {
        let doc = document(),p = board();doc.add(p);doc.select(p.id)
        var hardware = HardwareTemplate();hardware.name = "Measured pull";hardware.pattern.placement = .fixed;hardware.pattern.columns = 2;hardware.pattern.pitch.x = 4;hardware.unitCost = 3;hardware.quantityPerUse = 2
        XCTAssertTrue(doc.applyHardwareTemplate(hardware,parts:[p.id]),doc.status)
        XCTAssertEqual(doc.part(p.id)?.patterns?.count,1)
        var shop = PartShopData();shop.bandedEdges = [.lengthMin,.widthMax];shop.bandThickness = 0.04;shop.roughAllowance = 0.25
        XCTAssertTrue(doc.transaction { doc.parts[0].shop = shop })
        var rate = MaterialRate(species:.plywood,perSquareFoot:2,perBoardFoot:0,bandPerFoot:1.2)
        XCTAssertTrue(doc.transaction { doc.studio.materialRates = [rate] })
        let estimate = ShopPlanning.estimate(doc.project,layout:CNCAnalysis.layout(doc.project))
        XCTAssertEqual(estimate.hardware,6);XCTAssertEqual(estimate.banding,shop.bandLength(p)/12*1.2,accuracy:1e-8)
        XCTAssertEqual(shop.finished(p).x,16.04,accuracy:1e-8)
        XCTAssertTrue(ShopPlanning.schedule(doc.project).contains(Units.format(16.5,metric:false)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("hardware.json")
        let store = HardwareTemplateStore(url:url);try store.save([hardware]);XCTAssertEqual(store.load(),[hardware])
        rate.bandPerFoot = nil;XCTAssertNil(rate.bandPerFoot)
    }
    func testThreeRecoveryVersionsAndInvalidIncomingDoesNotReplaceValidFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url = root.appendingPathComponent("recovery.json")
        func data(_ i: Int) throws -> Data { var p = Project();p.parts = [board("Version \(i)")];return try JSONEncoder().encode(Document.Recovery(project:p,originalURL:nil,name:"Version \(i)")) }
        let validate: (Data) throws -> Void = { data in let r = try JSONDecoder().decode(Document.Recovery.self,from:data);try ModelValidation.validate(r.project) }
        for i in 1...4 { try ProjectStorage.write(data(i),to:url,validatePrevious:validate) }
        let backups = ProjectStorage.backupURLs(url)
        XCTAssertEqual(try JSONDecoder().decode(Document.Recovery.self,from:Data(contentsOf:backups[2])).name,"Version 1")
        XCTAssertThrowsError(try ProjectStorage.write(Data("invalid".utf8),to:url,validatePrevious:validate))
        XCTAssertEqual(try ProjectStorage.recovery(at:url).name,"Version 4")
        try Data("corrupt".utf8).write(to:url);try Data("corrupt".utf8).write(to:backups[0])
        XCTAssertEqual(try ProjectStorage.recovery(at:url).name,"Version 2")
    }
    func testValidationPackageContainsBothUnitSystemsAndAuditedVectors() throws {
        _ = NSApplication.shared
        let artifacts = try ShopValidation.artifacts()
        XCTAssertTrue(artifacts.contains { $0.name.hasPrefix("Inches - ") && $0.name.contains("BOTTOM") && $0.name.hasSuffix(".dxf") })
        XCTAssertTrue(artifacts.contains { $0.name.hasPrefix("Millimeters - ") && $0.name.contains("SIDE") && $0.name.hasSuffix(".dxf") })
        for artifact in artifacts where artifact.name.hasSuffix(".dxf") {
            let metric = artifact.name.hasPrefix("Millimeters")
            XCTAssertGreaterThan(try CNCVectorAudit.validate(artifact.data,metric:metric).polylines,0)
        }
        for artifact in artifacts where artifact.name.hasSuffix(".pdf") { XCTAssertGreaterThan(PDFDocument(data:artifact.data)?.pageCount ?? 0,0,artifact.name) }
        XCTAssertThrowsError(try CNCVectorAudit.validate(Data("broken".utf8),metric:false))
        if let folder = ProcessInfo.processInfo.environment["WOODSHOP_VALIDATION_OUTPUT_DIR"] {
            let destination = URL(fileURLWithPath:folder).appendingPathComponent("VCarve validation sample " + UUID().uuidString.prefix(6))
            try VCarveExport.write(artifacts,to:destination)
        }
    }
    func testShopWindowPanelsFitAndCanBeCaptured() throws {
        _ = NSApplication.shared
        let doc = document(),p = board();doc.add(p);doc.select(p.id)
        for tab in 0...5 {
            doc.shopTab = tab
            let host = NSHostingView(rootView:CutListView(doc:doc));host.frame = CGRect(x:0,y:0,width:1060,height:790)
            let window = NSWindow(contentRect:host.bounds,styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = host
            host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.04))
            XCTAssertLessThanOrEqual(host.fittingSize.width,1061,"Shop tab \(tab) width")
            XCTAssertLessThanOrEqual(host.fittingSize.height,791,"Shop tab \(tab) height")
            if let folder = ProcessInfo.processInfo.environment["WOODSHOP_UI_PREVIEW_DIR"],let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:folder).appendingPathComponent("shop-\(tab).png"))
            }
            window.contentView = nil;window.close()
        }
    }
}
