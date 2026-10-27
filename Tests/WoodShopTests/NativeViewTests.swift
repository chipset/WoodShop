import XCTest
import SwiftUI
import AppKit
import SceneKit
@testable import WoodShop

final class NativeViewTests: XCTestCase {
    func testCurveEditingRebuildsSceneAndEditorFits() throws {
        _ = NSApplication.shared
        let doc = Document(startRecoveryTimer: false)
        var part = Part(name: "Curved rail", origin: .zero, size: SIMD3(10, 0.75, 4), species: .walnut)
        part.thicknessAxis = 1; part.grainDirection = 0
        doc.add(part)
        let ctrl = SceneController(doc: doc)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let node = try XCTUnwrap(ctrl.scene.rootNode.childNode(withName: part.id.uuidString, recursively: true))
        let before = try XCTUnwrap(node.geometry?.sources(for: .vertex).first?.vectorCount)
        doc.edit(part.id) { $0.profile = .preset(.rail, part: $0) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(node.geometry?.sources(for: .vertex).first?.vectorCount ?? 0, before)
        let current = try XCTUnwrap(doc.selectedPart)
        let editor = NSHostingView(rootView: ProfileEditor(doc: doc, part: current))
        editor.frame = CGRect(x: 0, y: 0, width: 850, height: 575)
        editor.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(editor.fittingSize.width, 850)
        XCTAssertGreaterThan(Drawing.pdf(parts: [current], title: "Curves", metric: true).count, 1000)
        if let directory = ProcessInfo.processInfo.environment["WOODSHOP_CURVE_PREVIEW_DIR"] {
            ctrl.zoomExtents()
            let renderer = SCNRenderer(device: nil, options: nil)
            renderer.scene = ctrl.scene; renderer.pointOfView = ctrl.cameraNode
            let snapshot = renderer.snapshot(atTime: 0, with: CGSize(width: 1100, height: 800), antialiasingMode: .multisampling4X)
            if let tiff = snapshot.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("curves-model.png"))
            }
            for (name, view) in [("curves-editor", editor as NSView),
                                 ("curves-workspace", NSHostingView(rootView: ContentView(doc: doc, ctrl: ctrl)) as NSView)] {
                if name == "curves-workspace" { view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900); ctrl.zoomExtents() }
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
                    }
                }
            }
        }
    }

    func testMoveAcceptsTypedDistanceAfterReleaseAndEscapeRestoresDrag() throws {
        _ = NSApplication.shared
        let doc = Document(startRecoveryTimer: false)
        var part = Part(name: "Test", origin: .zero, size: SIMD3(10, 0.75, 4), species: .oak)
        part.thicknessAxis = 1; part.grainDirection = 0
        doc.add(part); doc.tool = .move
        let ctrl = SceneController(doc: doc)
        ctrl.target = part.center; ctrl.distance = 40; ctrl.updateCamera()
        let view = ModelView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.doc = doc; view.ctrl = ctrl; view.scene = ctrl.scene; view.pointOfView = ctrl.cameraNode
        view.connectActions()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let center = view.projectPoint(vec(part.center))
        let start = CGPoint(x: CGFloat(center.x), y: CGFloat(center.y))
        view.mouseDown(with: mouse(.leftMouseDown, start))
        XCTAssertTrue(doc.activeDrag)
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x + 30, y: start.y)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: start.x + 30, y: start.y)))
        XCTAssertTrue(doc.activeDrag, "Typed distances must remain available after releasing the mouse")
        doc.applyDistance?(3.5)
        XCTAssertEqual(doc.part(part.id)?.origin.x ?? .nan, 3.5, accuracy: 1e-9)
        XCTAssertFalse(doc.activeDrag)
        doc.undo()
        XCTAssertEqual(doc.part(part.id)?.origin, part.origin)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        view.mouseDown(with: mouse(.leftMouseDown, start))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x + 40, y: start.y)))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        XCTAssertEqual(doc.part(part.id)?.origin, part.origin)
        XCTAssertTrue(doc.canRedo)
    }
    func testCncAndParametricPanelsLayoutAndPreview() throws {
        _ = NSApplication.shared
        let doc = Document(startRecoveryTimer:false)
        doc.insertParametricBookcase(); doc.fabricationTab = 1
        let ctrl = SceneController(doc:doc)
        func inspect<V: View>(_ root: V, size: CGSize, name: String) throws {
            let host = NSHostingView(rootView:root); host.frame = CGRect(origin:.zero,size:size)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.03))
            XCTAssertLessThanOrEqual(host.fittingSize.width,size.width + 1)
            XCTAssertLessThanOrEqual(host.fittingSize.height,size.height + 1)
            if let directory = ProcessInfo.processInfo.environment["WOODSHOP_PREVIEW_DIRECTORY"],let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:rep)
                try rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent(name + ".png"))
            }
        }
        try inspect(CutListView(doc:doc),size:CGSize(width:1060,height:790),name:"cnc-layout")
        try inspect(DesignPanel(doc:doc),size:CGSize(width:940,height:740),name:"parameters-history")
        try inspect(WorkshopView(doc:doc,ctrl:ctrl),size:CGSize(width:1000,height:800),name:"machining")
    }
    func testWorkspaceAndFabricationViewsLayout() throws {
        _ = NSApplication.shared
        let doc = Document(startRecoveryTimer: false)
        doc.insertExample()
        let ctrl = SceneController(doc: doc)
        let workspace = NSHostingView(rootView: ContentView(doc: doc, ctrl: ctrl))
        workspace.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        workspace.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        XCTAssertTrue(descendants(workspace).contains { $0 is ModelView })
        XCTAssertLessThanOrEqual(workspace.fittingSize.width, 1440)
        let fabrication = NSHostingView(rootView: CutListView(doc: doc))
        fabrication.frame = CGRect(x: 0, y: 0, width: 1060, height: 790)
        fabrication.layoutSubtreeIfNeeded()
        XCTAssertEqual(fabrication.fittingSize.width, 1060, accuracy: 1)
        doc.fabricationTab = 1
        fabrication.layoutSubtreeIfNeeded()
        XCTAssertEqual(fabrication.fittingSize.height, 790, accuracy: 1)
        if let path = ProcessInfo.processInfo.environment["WOODSHOP_PREVIEW_PATH"],
           let rep = workspace.bitmapImageRepForCachingDisplay(in: workspace.bounds) {
            workspace.cacheDisplay(in: workspace.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: path)) }
        }
    }
}
