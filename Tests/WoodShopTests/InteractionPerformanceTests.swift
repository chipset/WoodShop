import XCTest
import AppKit
import SceneKit
import SwiftUI
@testable import WoodShop

final class InteractionPerformanceTests: XCTestCase {
    func testLargeSceneBatchesUnselectedEdgesAndRestoresSelectedOutline() throws {
        _ = NSApplication.shared
        let doc = Document(startRecoveryTimer:false)
        doc.parts = (0..<205).map { i in
            Part(name:"Board \(i)",origin:SIMD3(Double(i)*2,0,0),size:SIMD3(1,0.75,8),species:.plywood)
        }
        let ctrl = SceneController(doc:doc)
        let deadline = Date().addingTimeInterval(5)
        repeat { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) } while ctrl.loadingProgress != nil && Date() < deadline
        XCTAssertNil(ctrl.loadingProgress)
        XCTAssertGreaterThan(ctrl.batchedEdgeNodeCount,0)
        XCTAssertLessThan(ctrl.batchedEdgeNodeCount,10)
        let first = try XCTUnwrap(ctrl.scene.rootNode.childNode(withName:doc.parts[0].id.uuidString,recursively:true))
        let second = try XCTUnwrap(ctrl.scene.rootNode.childNode(withName:doc.parts[1].id.uuidString,recursively:true))
        XCTAssertTrue(first.childNodes[0].isHidden)
        doc.select(doc.parts[0].id)
        RunLoop.main.run(until:Date().addingTimeInterval(0.02))
        XCTAssertFalse(first.childNodes[0].isHidden)
        XCTAssertTrue(second.childNodes[0].isHidden)
    }

    func testLargeSceneBuildsMachiningPickGeometryWhenRequested() throws {
        _ = NSApplication.shared
        let doc = Document(startRecoveryTimer:false)
        doc.parts = (0..<201).map { i in
            var part = Part(name:"Panel \(i)",origin:SIMD3(Double(i)*2,0,0),size:SIMD3(1,0.75,8),species:.plywood)
            if i == 0 { part.cuts = [Cut(kind:"Pocket",lo:SIMD3(0.1,0.25,1),hi:SIMD3(0.9,0.75,2),faceAxis:1,facePositive:true)] }
            return part
        }
        let ctrl = SceneController(doc:doc)
        let deadline = Date().addingTimeInterval(5)
        repeat { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) } while ctrl.loadingProgress != nil && Date() < deadline
        XCTAssertNil(ctrl.loadingProgress)
        let body = try XCTUnwrap(ctrl.scene.rootNode.childNode(withName:doc.parts[0].id.uuidString,recursively:true))
        XCTAssertEqual(body.childNodes[1].childNodes.count,0)
        ctrl.ensureFeatureProxies(for:doc.parts[0].id)
        XCTAssertGreaterThan(body.childNodes[1].childNodes.count,0)
    }

    func testPreparedComplexGeometryMatchesDirectBuild() throws {
        _ = NSApplication.shared
        var part = Part(name:"Pocket panel",origin:.zero,size:SIMD3(12,0.75,8),species:.plywood)
        part.cuts = [Cut(kind:"Pocket",lo:SIMD3(2,0.25,2),hi:SIMD3(5,0.75,5),faceAxis:1,facePositive:true)]
        let prepared = try XCTUnwrap(PartNode.prepare(part))
        let direct = PartNode(part), staged = PartNode(part,prepared:prepared)
        XCTAssertEqual(direct.polygons.count,staged.polygons.count)
        XCTAssertEqual(direct.body.geometry?.sources(for:.vertex).first?.vectorCount,
                       staged.body.geometry?.sources(for:.vertex).first?.vectorCount)
        XCTAssertEqual(direct.featureProxies.childNodes.count,staged.featureProxies.childNodes.count)
    }

    func testRejectedMoveNeverPublishesInvalidParts() {
        let doc = Document(startRecoveryTimer:false)
        let part = Part(name:"Panel",origin:.zero,size:SIMD3(12,0.75,8),species:.plywood)
        doc.parts = [part]
        let revision = doc.partsRevision
        var invalid = part; invalid.origin.x = .nan
        XCTAssertFalse(doc.applyPartChanges([invalid]))
        XCTAssertEqual(doc.partsRevision,revision)
        XCTAssertEqual(doc.parts[0].origin,part.origin)
    }

    func testRepeatedBoardsShareMeshDataButKeepSelectionMaterialsIndependent() {
        _ = NSApplication.shared
        let part = Part(name:"Panel",origin:.zero,size:SIMD3(12,0.75,8),species:.plywood)
        let first = PartNode(part), second = PartNode(part)
        XCTAssertEqual(first.polygons.count,second.polygons.count)
        XCTAssertTrue(first.body.geometry?.sources.first === second.body.geometry?.sources.first)
        XCTAssertFalse(first.body.geometry?.firstMaterial === second.body.geometry?.firstMaterial)
        first.setSelected(true)
        XCTAssertNotEqual(first.edges.geometry?.firstMaterial?.diffuse.contents as? NSColor,
                          second.edges.geometry?.firstMaterial?.diffuse.contents as? NSColor)
    }

    func testStatusChangesOnlyPublishToStatusView() {
        let doc = Document(startRecoveryTimer:false)
        var wholeDocumentChanges = 0
        let subscription = doc.objectWillChange.sink { wholeDocumentChanges += 1 }
        doc.status = "Previewing movement"
        XCTAssertEqual(doc.statusState.value,"Previewing movement")
        XCTAssertEqual(wholeDocumentChanges,0)
        withExtendedLifetime(subscription) {}
    }

    func testPartRevisionInvalidatesSnappingInputs() {
        let doc = Document(startRecoveryTimer:false)
        let first = doc.partsRevision
        let part = Part(name:"Panel",origin:.zero,size:SIMD3(12,0.75,8),species:.plywood)
        doc.parts.append(part)
        XCTAssertGreaterThan(doc.partsRevision,first)
        let second = doc.partsRevision
        doc.parts[0].origin.x = 4
        XCTAssertGreaterThan(doc.partsRevision,second)
    }

    func testProjectedNearestKeepsFirstTieAndTolerance() {
        let candidates = [InferencePoint(point:SIMD3(1,0,0),label:"first"),InferencePoint(point:SIMD3(2,0,0),label:"second")]
        let projected = [SIMD2<Double>(5,0),SIMD2<Double>(-5,0)]
        XCTAssertEqual(Inference.nearest(.zero,candidates:candidates,projected:projected,tolerance:5)?.label,"first")
        XCTAssertNil(Inference.nearest(.zero,candidates:candidates,projected:projected,tolerance:4))
    }

    func testOptionalLargeProjectInteractionBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["WOODSHOP_PERF_INPUT"] else { return }
        _ = NSApplication.shared
        let project = try Document.decodeProject(Data(contentsOf:URL(fileURLWithPath:path)))
        let doc = Document(startRecoveryTimer:false)
        let clock = ProcessInfo.processInfo
        let start = clock.systemUptime
        doc.restore(project)
        let controller = SceneController(doc:doc)
        RunLoop.main.run(until:Date().addingTimeInterval(0.02))
        while controller.loadingProgress != nil && clock.systemUptime-start < 10 { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        XCTAssertNil(controller.loadingProgress)
        let sceneSeconds = clock.systemUptime-start
        let view = ModelView(frame:CGRect(x:0,y:0,width:900,height:650))
        view.doc = doc;view.ctrl = controller;view.scene = controller.scene;view.pointOfView = controller.cameraNode
        controller.viewport = view
        func event(_ x: CGFloat,_ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with:.mouseMoved,location:CGPoint(x:x,y:y),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:0,pressure:0)!
        }
        let selectStart = clock.systemUptime
        for i in 0..<60 { view.mouseMoved(with:event(CGFloat(100+i*7),300)) }
        let selectSeconds = clock.systemUptime-selectStart
        doc.tool = .tape
        let snapStart = clock.systemUptime
        view.mouseMoved(with:event(100,310))
        let firstSnapSeconds = clock.systemUptime-snapStart
        for i in 1..<20 { view.mouseMoved(with:event(CGFloat(100+i*13),310)) }
        let snapSeconds = clock.systemUptime-snapStart
        controller.orbit(dx:10,dy:10)
        let orbitStart = clock.systemUptime
        view.mouseMoved(with:event(230,310))
        let orbitSnapSeconds = clock.systemUptime-orbitStart
        doc.tool = .select
        let selectionStart = clock.systemUptime
        for part in project.parts.prefix(10) {
            doc.select(part.id)
            RunLoop.main.run(until:Date().addingTimeInterval(0.001))
        }
        let selectionSeconds = clock.systemUptime-selectionStart
        let makeStart = clock.systemUptime
        doc.openMake(.prepare)
        let host = NSHostingView(rootView:CutListView(doc:doc));host.frame = CGRect(x:0,y:0,width:1060,height:790)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until:Date().addingTimeInterval(0.01))
        let makeSeconds = clock.systemUptime-makeStart
        let source = try XCTUnwrap(doc.parts.first)
        let previewStart = clock.systemUptime
        for i in 0..<60 {
            var moved = source; moved.origin.x += Double(i+1) / 64
            controller.previewMove([moved])
        }
        let movePreviewSeconds = clock.systemUptime-previewStart
        controller.endEditPreview(committed:false)
        let resizeStart = clock.systemUptime
        for i in 0..<10 {
            var resized = source; resized.size.x += Double(i+1) / 64
            controller.previewPart(resized)
        }
        let resizePreviewSeconds = clock.systemUptime-resizeStart
        controller.endEditPreview(committed:false)
        let free = Part(name:"Interaction benchmark",origin:SIMD3(2000,0,0),size:SIMD3(12,0.75,8),species:.plywood)
        doc.parts.append(free)
        var movedFree = free; movedFree.origin.x += 1
        let commitStart = clock.systemUptime
        XCTAssertTrue(doc.applyPartChanges([movedFree]))
        let commitSeconds = clock.systemUptime-commitStart
        print(String(format:"INTERACTION PERF %d parts scene %.3fs build %.3fs max-batch %.3fs max-part %.3fs select-hover-60 %.3fs snap-first %.3fs snap-hover-20 %.3fs snap-after-orbit %.3fs select-10 %.3fs make-open %.3fs move-preview-60 %.3fs resize-preview-10 %.3fs model-commit %.3fs",project.parts.count,sceneSeconds,controller.lastSceneLoadSeconds,controller.longestSceneBatchSeconds,controller.longestScenePartSeconds,selectSeconds,firstSnapSeconds,snapSeconds,orbitSnapSeconds,selectionSeconds,makeSeconds,movePreviewSeconds,resizePreviewSeconds,commitSeconds))
        XCTAssertNotNil(controller.scene.rootNode.childNode(withName:project.parts[0].id.uuidString,recursively:true))
        XCTAssertEqual(doc.selectedIDs.count,1)
        XCTAssertEqual(MakeRoute.current(doc),.prepare)
    }
}
