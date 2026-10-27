import XCTest
import AppKit
import PDFKit
@testable import WoodShop

/// Exercise user-generated projects against the same loader, expressions, and export path as the app.
final class ImportedProjectTests: XCTestCase {
    func testImportedProjectRoundTripAndDeliverables() throws {
        guard let input = ProcessInfo.processInfo.environment["WOODSHOP_PROJECT_INPUT"] else { return }
        _ = NSApplication.shared
        let project = try Document.decodeProject(Data(contentsOf:URL(fileURLWithPath:input)))
        XCTAssertTrue(try Document.decodeProject(JSONEncoder().encode(project)) == project)
        var regenerated = project.parts
        try Regeneration.rebuild(parts:&regenerated,links:project.links,studio:project.studio ?? StudioState())
        XCTAssertTrue(regenerated == project.parts,"The saved model must already contain evaluated feature definitions: " + zip(regenerated,project.parts).filter { $0 != $1 }.map { $0.0.name }.joined(separator:", "))
        let issues = MachiningReview.issues(project:project),errors = issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty,errors.map(\.message).joined(separator:"\n"))
        if project.studio?.parameters?.contains(where: { $0.name == "saw_opening" }) == true {
            let values = try Parametric.values(project.studio!.parameters!)
            XCTAssertEqual(values["overall_width"]!.value,228.875,accuracy:1e-8)
            XCTAssertEqual(project.parts.filter { $0.name == "Plywood drawer runner" }.count,80)
            XCTAssertEqual(project.parts.filter { $0.name == "Bottom plywood runner" }.count,10)
            XCTAssertEqual(project.parts.filter { $0.name == "Drawer bottom / wooden slide" }.count,30)
            XCTAssertEqual(project.parts.filter { $0.name == "Inset door" }.count,15)
            let platformBack = try XCTUnwrap(project.parts.first { $0.name == "Platform back" })
            XCTAssertEqual(platformBack.size.x,27.375,accuracy:1e-8)
            let doors = project.parts.filter { $0.group == "Wittworks/07 Saw upper bridge" && $0.name == "Inset door" }
            XCTAssertEqual(doors.count,2); XCTAssertEqual(doors[0].size.x,13.5,accuracy:1e-8)
            for part in project.parts.filter({ $0.name == "Drawer bottom / wooden slide" }) {
                XCTAssertEqual(part.size.x,18.375,accuracy:1e-8); XCTAssertEqual(part.size.z,20.25,accuracy:1e-8)
            }
        }
        let viewportDocument = WoodShop.Document(startRecoveryTimer:false);viewportDocument.restore(project)
        let viewport = SceneController(doc:viewportDocument)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        for part in project.parts { XCTAssertNotNil(viewport.scene.rootNode.childNode(withName:part.id.uuidString,recursively:true),part.name) }
        guard let output = ProcessInfo.processInfo.environment["WOODSHOP_PROJECT_OUTPUT"] else { return }
        let folder = URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data(CutList.csv(CutList.rows(project.parts),metric:project.metric).utf8).write(to:folder.appendingPathComponent("Cut list.csv"),options:.atomic)
        let drawings = Drawing.pdf(parts:project.parts.filter { $0.hardware != true },title:"Wittworks-derived miter station",metric:project.metric,dimensions:project.studio?.dimensions ?? [])
        XCTAssertGreaterThan(PDFDocument(data:drawings)?.pageCount ?? 0,1)
        try drawings.write(to:folder.appendingPathComponent("Shop drawings.pdf"),options:.atomic)
        try ShopDocuments.labels(project:project).write(to:folder.appendingPathComponent("Part labels.pdf"),options:.atomic)
        let preview = ModelPreview(parts:project.parts)
        for (index,scene) in (project.studio?.scenes ?? []).enumerated() {
            try preview.png(project:project,view:scene).write(to:folder.appendingPathComponent(["Complete model.png","Interior construction.png","Front elevation.png","Wooden runner system.png"][index]),options:.atomic)
        }
        let d = Document(startRecoveryTimer:false);d.restore(project)
        var definitions = d.studio.parameters!
        if let i = definitions.firstIndex(where: { $0.name == "saw_opening" }) {
            definitions[i].expression = "30in"
            XCTAssertTrue(d.setParameters(definitions),d.status)
            XCTAssertEqual(d.parts.count,project.parts.count)
            XCTAssertEqual(d.parts.first { $0.name == "Platform back" }!.size.x,28.5,accuracy:1e-8)
            d.undo();XCTAssertTrue(d.parts == project.parts)
        }
    }
}
