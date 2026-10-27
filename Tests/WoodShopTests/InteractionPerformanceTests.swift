import XCTest
import AppKit
import SceneKit
import SwiftUI
@testable import WoodShop

final class InteractionPerformanceTests: XCTestCase {
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
        print(String(format:"INTERACTION PERF %d parts scene %.3fs select-hover-60 %.3fs snap-first %.3fs snap-hover-20 %.3fs snap-after-orbit %.3fs select-10 %.3fs make-open %.3fs",project.parts.count,sceneSeconds,selectSeconds,firstSnapSeconds,snapSeconds,orbitSnapSeconds,selectionSeconds,makeSeconds))
        XCTAssertNotNil(controller.scene.rootNode.childNode(withName:project.parts[0].id.uuidString,recursively:true))
        XCTAssertEqual(doc.selectedIDs.count,1)
        XCTAssertEqual(MakeRoute.current(doc),.prepare)
    }
}
