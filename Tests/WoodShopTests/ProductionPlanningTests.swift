import XCTest
import AppKit
import PDFKit
import simd
@testable import WoodShop

final class ProductionPlanningTests: XCTestCase {
    private func panel(_ name: String,_ order: Int,size: SIMD3<Double> = SIMD3(10,0.75,7)) -> Part {
        var part = Part(name:name,origin:.zero,size:size,species:.plywood)
        part.thicknessAxis = 1;part.grainDirection = 0
        part.shop = PartShopData(grainMatchGroup:"Door run",grainMatchOrder:order)
        return part
    }
    func testGrainRunStaysOnOneSheetInExplicitOrderAndExportsMap() throws {
        let parts = [panel("Third",3),panel("First",1),panel("Second",2)]
        var project = Project();project.parts = parts;project.sheetLength = 24;project.sheetWidth = 24;project.nestGap = 0.25
        let layout = Nesting.nest(parts.map(Flatten.flat),sheetL:24,sheetW:24,gap:0.25)
        XCTAssertTrue(layout.oversize.isEmpty,layout.oversize.description)
        XCTAssertEqual(layout.placed.count,3)
        let run = layout.placed.sorted { $0.y < $1.y }
        XCTAssertEqual(run.compactMap { $0.part.grainMatchOrder },[1,2,3])
        XCTAssertEqual(Set(run.map(\.sheet)).count,1)
        XCTAssertEqual(run.map { $0.x-layout.sheets[$0.sheet].x }.max()!,run.map { $0.x-layout.sheets[$0.sheet].x }.min()!,accuracy:1e-8)
        XCTAssertGreaterThanOrEqual(run[1].y-run[0].y,run[0].part.width+0.25-1e-8)
        let map = ShopPlanning.grainMatchMap(ShopIdentity.numbered(project),layout:layout)
        XCTAssertTrue(map.contains("Door run"));XCTAssertTrue(map.contains("Cross-grain start"))
        _ = NSApplication.shared
        let files = try VCarveExport.artifacts(project:project)
        let exported = try XCTUnwrap(files.first { $0.name == "Grain match map.csv" })
        XCTAssertEqual(String(data:exported.data,encoding:.utf8)?.components(separatedBy:"\r\n").count,5)
        let job = try JSONDecoder().decode(VCarveJob.self,from:XCTUnwrap(files.first { $0.name == "Setup and parameters.json" }).data)
        XCTAssertEqual(job.placements.compactMap(\.grainMatchOrder).sorted(),[1,2,3])
        let copy = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project))
        XCTAssertEqual(copy.parts.compactMap { $0.shop?.grainMatchOrder },[3,1,2])
    }
    func testGrainRunReportsWhenItCannotFitAWholeSheet() throws {
        let parts = [panel("A",1),panel("B",2),panel("C",3)]
        let layout = Nesting.nest(parts.map(Flatten.flat),sheetL:24,sheetW:15,gap:0.25)
        XCTAssertEqual(layout.placed.count,0)
        XCTAssertEqual(layout.oversize.count,1)
        XCTAssertTrue(layout.oversize[0].contains("Grain match"))
        var project = Project();project.parts = parts;project.sheetLength = 24;project.sheetWidth = 15;project.nestGap = 0.25
        XCTAssertThrowsError(try VCarveExport.artifacts(project:project))
        project.parts[1].shop?.grainMatchOrder = 1
        XCTAssertThrowsError(try ModelValidation.validate(project))
    }
    func testManufacturerTemplatesIdentifyVerifiedAndEditableMeasurements() throws {
        let cup = try XCTUnwrap(HardwareTemplate.examples.first { $0.partNumber == "71B3550" })
        let plate = try XCTUnwrap(HardwareTemplate.examples.first { $0.partNumber == "173H7100" })
        XCTAssertEqual(cup.pattern.diameter*25.4,35,accuracy:1e-8)
        XCTAssertEqual(cup.pattern.depth*25.4,13,accuracy:1e-8)
        XCTAssertEqual(plate.pattern.origin.x*25.4,37,accuracy:1e-8)
        XCTAssertEqual(plate.pattern.pitch.y*25.4,32,accuracy:1e-8)
        XCTAssertTrue(cup.sourceURL?.hasPrefix("https://www.blum.com/") == true)
        XCTAssertTrue(plate.sourceURL?.hasPrefix("https://publications.blum.com/") == true)
        XCTAssertTrue(plate.notes.contains("not specified by Blum"))
        try cup.validate();try plate.validate()
        XCTAssertEqual(try cup.pattern.generated(size:SIMD3(16,0.75,12)).count,1)
        XCTAssertEqual(try plate.pattern.generated(size:SIMD3(16,0.75,12)).count,2)
        var installed = panel("Door",1);installed.shop = nil
        var hole = cup.pattern;hole.hardwareTemplateID = cup.id;installed.patterns = [hole]
        var project = Project();project.parts = [installed];var studio = StudioState();studio.hardwareTemplates = [cup];project.studio = studio
        try ModelValidation.validate(project)
        XCTAssertTrue(ShopPlanning.hardwareSchedule(project).contains("71B3550"))
        let copy = try JSONDecoder().decode(HardwareTemplate.self,from:JSONEncoder().encode(cup))
        XCTAssertEqual(copy,cup)
    }
    func testExplodedGuideIncludesNumberedDimensionedStepPages() throws {
        _ = NSApplication.shared
        var project = Project();project.parts = [panel("Left",1),panel("Right",2)]
        let pdf = try XCTUnwrap(PDFDocument(data:ExplodedGuide.pdf(project:project)))
        XCTAssertGreaterThanOrEqual(pdf.pageCount,2)
        let text = pdf.string ?? ""
        XCTAssertTrue(text.contains("Assembly step"),text)
        XCTAssertTrue(text.contains("PARTS AND FINISHED CORE DIMENSIONS"),text)
        XCTAssertTrue(text.contains("P001"),text)
    }
    func testPerformanceReportMeasuresRealOperations() throws {
        var project = Project();project.parts = (0..<20).map { index in
            var part = panel("Panel \(index)",index+1,size:SIMD3(6,0.75,3));part.shop = nil;return part
        }
        project.sheetLength = 48;project.sheetWidth = 48
        let report = PerformanceAudit.run(project)
        XCTAssertEqual(report.partCount,20)
        XCTAssertEqual(report.measures.map(\.name),["Project validation","Parametric regeneration","CNC flattening","Sheet nesting"])
        XCTAssertTrue(report.measures.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 && $0.error == nil },report.summary)
        XCTAssertTrue(report.summary.contains("target"))
    }
    func testOptionalFiveHundredPartBenchmark() throws {
        guard ProcessInfo.processInfo.environment["WOODSHOP_PERFORMANCE_500"] == "1" else { return }
        var project = Project();project.sheetLength = 96;project.sheetWidth = 48
        project.parts = (0..<500).map { index in
            var part = panel("Bench panel \(index)",index+1,size:SIMD3(4,0.75,3));part.shop = nil;return part
        }
        let report = PerformanceAudit.run(project)
        print(report.summary)
        XCTAssertTrue(report.measures.allSatisfy { $0.error == nil && $0.seconds.isFinite },report.summary)
        if let folder = ProcessInfo.processInfo.environment["WOODSHOP_PERFORMANCE_OUTPUT_DIR"] {
            try FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
            try JSONEncoder().encode(report).write(to:URL(fileURLWithPath:folder).appendingPathComponent("500-part-performance.json"))
        }
    }
    func testOptionalImportedProjectBenchmark() throws {
        guard let input = ProcessInfo.processInfo.environment["WOODSHOP_PROJECT_INPUT"] else { return }
        let project = try Document.decodeProject(Data(contentsOf:URL(fileURLWithPath:input)))
        let report = PerformanceAudit.run(project)
        print("IMPORTED PROJECT PERFORMANCE\n"+report.summary)
        XCTAssertTrue(report.measures.allSatisfy { $0.error == nil && $0.seconds.isFinite },report.summary)
        _ = NSApplication.shared
        let guide = ExplodedGuide.pdf(project:project)
        let pdf = try XCTUnwrap(PDFDocument(data:guide))
        XCTAssertGreaterThan(pdf.pageCount,10)
        XCTAssertTrue((pdf.string ?? "").contains("PARTS AND FINISHED CORE DIMENSIONS"))
        if let folder = ProcessInfo.processInfo.environment["WOODSHOP_PERFORMANCE_OUTPUT_DIR"] {
            try FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
            try JSONEncoder().encode(report).write(to:URL(fileURLWithPath:folder).appendingPathComponent("imported-project-performance.json"))
            try guide.write(to:URL(fileURLWithPath:folder).appendingPathComponent("Imported project exploded assembly.pdf"))
        }
    }
}
