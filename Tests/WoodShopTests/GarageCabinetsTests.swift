import XCTest
import AppKit
import SceneKit
import PDFKit
import simd
@testable import WoodShop

final class GarageCabinetsTests: XCTestCase {
    func testCompleteLayoutAndMachiningAreValid() throws {
        let project = try GarageCabinets.project(),parts = project.parts
        XCTAssertNoThrow(try ModelValidation.validate(project))
        XCTAssertEqual(parts.filter { $0.name.contains("applied front") }.count,8)
        XCTAssertEqual(parts.filter { $0.name.contains("slab door") }.count,12)
        XCTAssertEqual(parts.filter { $0.name == "Captured drawer bottom" }.count,8)
        XCTAssertEqual(parts.filter { $0.name.contains("side-mount slide") }.count,16)
        XCTAssertEqual(parts.filter { $0.name.contains("Adjustable") }.count,14)
        XCTAssertEqual(parts.filter { $0.name == "Shelf support pin" }.count,56)
        XCTAssertEqual(parts.filter { $0.name.contains("Worktop section") }.count,2)
        XCTAssertEqual(parts.filter { $0.name.contains("fixing cleat") }.count,8)
        for side in parts.filter({ $0.name.contains("drawer box side") }) {
            XCTAssertGreaterThanOrEqual(side.origin.y,5)
            XCTAssertLessThanOrEqual(side.hi.y,33.5+1e-7)
        }
        XCTAssertEqual(Set(parts.compactMap(\.shopNumber)).count,parts.count)
        XCTAssertEqual(try Parametric.values(project.studio!.parameters!)["overall_width"]!.value,144)
        XCTAssertEqual(try Parametric.values(project.studio!.parameters!)["worktop_height"]!.value,36)
        let errors = MachiningReview.issues(project:project).filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty,errors.map(\.message).joined(separator:"\n"))
        XCTAssertEqual(try Document.decodeProject(JSONEncoder().encode(project)),project)
    }
    func testModuleResizeKeepsDrawerClearanceAndPullCenters() throws {
        let original = try GarageCabinets.project()
        let d = Document(startRecoveryTimer:false); d.restore(original)
        var parameters = d.studio.parameters!
        parameters[parameters.firstIndex { $0.name == "module_width" }!].expression = "32in"
        XCTAssertTrue(d.setParameters(parameters),d.status)
        XCTAssertEqual(try Parametric.values(parameters)["overall_width"]!.value,152)
        let front = try XCTUnwrap(d.parts.first { $0.name == "Drawer 1 applied front" })
        let pattern = try XCTUnwrap(front.patterns?.first),holes = try pattern.generated(size:front.size)
        XCTAssertEqual(holes.count,2)
        let mid = (holes[0].openingBounds.center.x+holes[1].openingBounds.center.x)/2
        XCTAssertEqual(mid,front.size.x/2,accuracy:1e-7)
        XCTAssertNoThrow(try ModelValidation.validate(d.project))
        XCTAssertEqual(d.parts.count,original.parts.count)
    }
    func testGenerateGarageDeliverables() throws {
        guard let output = ProcessInfo.processInfo.environment["WOODSHOP_GARAGE_OUTPUT"] else { return }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let project = try GarageCabinets.project(),encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(project).write(to:folder.appendingPathComponent("Garage cabinets.wood"),options:.atomic)
        let artifacts = try VCarveExport.artifacts(project:project)
        try VCarveExport.write(artifacts,to:folder.appendingPathComponent("VCarve job"))
        try ShopDocuments.assembly(project:project).write(to:folder.appendingPathComponent("Assembly guide.pdf"),options:.atomic)
        try ShopDocuments.labels(project:project).write(to:folder.appendingPathComponent("Part labels.pdf"),options:.atomic)
        try Data(CutList.csv(CutList.rows(project.parts),metric:false).utf8).write(to:folder.appendingPathComponent("Cut list.csv"),options:.atomic)
        let hardware = project.parts.filter { $0.hardware == true }
        let counts = Dictionary(grouping:hardware,by:\.name).map { "\($0.value.count) × \($0.key)" }.sorted().joined(separator:"\n")
        try Data(counts.utf8).write(to:folder.appendingPathComponent("Hardware references.txt"),options:.atomic)
        let preview = ModelPreview(parts:project.parts)
        for (index,saved) in project.studio!.scenes.enumerated() {
            let png = try preview.png(project:project,view:saved)
            XCTAssertNotNil(NSBitmapImageRep(data:png))
            try png.write(to:folder.appendingPathComponent(["Complete model.png","Interior construction.png","Front elevation.png","Drawer boxes.png"][index]),options:.atomic)
        }
        let summary = "\(project.parts.count) parts, \(project.parts.filter { $0.hardware != true }.count) wood parts, \(project.studio!.matingJoints!.count) linked joints, \(artifacts.count) export files."
        try Data(summary.utf8).write(to:folder.appendingPathComponent("Model contents.txt"),options:.atomic)
    }
    func testBatchedPatternReplayMatchesSequentialCutters() throws {
        var part = Part(name:"Pin test",origin:.zero,size:SIMD3(12,0.75,10),species:.plywood)
        var pattern = DrillingPattern(); pattern.columns = 5; pattern.rows = 2; pattern.pitch = SIMD2(1,3)
        part.patterns = [pattern]
        let actual = FeatureReplay.polygons(part)
        var expected = FeatureReplay.polygons(part,through:0)
        for op in try pattern.generated(size:part.size) { expected = SolidCSG.subtract(expected,op.polygons(size:part.size)) }
        func volume(_ polygons: [Geo.Poly]) -> Double {
            var result = 0.0
            for p in polygons where p.pts.count >= 3 { for i in 1..<(p.pts.count-1) { result += simd_dot(p.pts[0],simd_cross(p.pts[i],p.pts[i+1]))/6 } }
            return result
        }
        XCTAssertEqual(volume(actual),volume(expected),accuracy:1e-7)
        XCTAssertTrue(actual.contains { $0.source == pattern.id })
        XCTAssertTrue(actual.allSatisfy { $0.pts.allSatisfy(ModelValidation.finite) })
    }

}
