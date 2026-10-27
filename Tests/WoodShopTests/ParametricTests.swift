import XCTest
@testable import WoodShop

final class ParametricTests: XCTestCase {
    func document() -> Document { Document(startRecoveryTimer: false, recoveryLocation: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    func board() -> Part { var p = Part(name: "Shelf", origin: .zero, size: SIMD3(20,0.75,10), species: .plywood); p.thicknessAxis = 1; p.grainDirection = 0; return p }
    func testExpressionsUnitsDependenciesAndErrors() throws {
        let definitions = [DesignParameter(name: "width", expression: "600mm"), DesignParameter(name: "thickness", expression: "18mm"), DesignParameter(name: "shelf", expression: "width - 2 * thickness"), DesignParameter(name: "half", expression: "shelf / 2")]
        let values = try Parametric.values(definitions)
        XCTAssertEqual(values["shelf"]!.value * 25.4, 564, accuracy: 1e-8)
        XCTAssertEqual(values["half"]!.value * 25.4, 282, accuracy: 1e-8)
        let expression = DesignBinding(target: .size, expression: "max(width / 2, shelf)")
        XCTAssertEqual(try Parametric.evaluate(expression, values: values) * 25.4, 564, accuracy: 1e-8)
        XCTAssertThrowsError(try Parametric.values([DesignParameter(name: "a", expression: "b"),DesignParameter(name: "b", expression: "a")]))
        XCTAssertThrowsError(try Parametric.values([DesignParameter(name: "a", expression: "1 / 0")]))
        XCTAssertThrowsError(try Parametric.values([DesignParameter(name: "a", expression: "missing + 1")]))
    }
    func testMetricBareConstantsAndScalarArithmetic() throws {
        let values = try Parametric.values([DesignParameter(name: "width", expression: "600", metricLiterals: true), DesignParameter(name: "count", expression: "3", kind: .scalar)])
        let b = DesignBinding(target: .size, expression: "width / count - 10", metricLiterals: true)
        XCTAssertEqual(try Parametric.evaluate(b, values: values) * 25.4, 190, accuracy: 1e-8)
    }
    func testParametersDrivePartsAndJointDepthAndUndo() throws {
        let doc = document(); var part = board()
        part.cuts = [Cut(kind: "Dado", lo: SIMD3(2,0.5,0),hi:SIMD3(3,0.75,10),faceAxis:1,facePositive:true,runAxis:2)]
        doc.add(part)
        XCTAssertTrue(doc.setParameters([DesignParameter(name: "width",expression:"600mm"),DesignParameter(name:"depth",expression:"6mm")]))
        doc.bind(DesignBinding(target:.size,axis:0,expression:"width - 36mm"),to:part.id)
        doc.bind(DesignBinding(target:.cutDepth,feature:part.cuts[0].id,expression:"depth"),to:part.id)
        XCTAssertEqual(doc.part(part.id)!.size.x * 25.4,564,accuracy:1e-8)
        let cut = doc.part(part.id)!.cuts[0]
        XCTAssertEqual((cut.hi.y-cut.lo.y)*25.4,6,accuracy:1e-8)
        var parameters = doc.studio.parameters!; parameters[0].expression = "800mm"
        XCTAssertTrue(doc.setParameters(parameters))
        XCTAssertEqual(doc.part(part.id)!.size.x*25.4,764,accuracy:1e-8)
        doc.undo(); XCTAssertEqual(doc.part(part.id)!.size.x*25.4,564,accuracy:1e-8)
        let decoded = try Document.decodeProject(JSONEncoder().encode(doc.project))
        XCTAssertEqual(decoded.parts[0].bindings?.count,2)
        XCTAssertNotNil(decoded.studio?.history)
    }
    func testInvalidParameterChangeIsAtomic() {
        let doc = document(), p = board(); doc.add(p)
        XCTAssertTrue(doc.setParameters([DesignParameter(name:"width",expression:"20in")]))
        doc.bind(DesignBinding(target:.size,axis:0,expression:"width"),to:p.id)
        let before = doc.designSnapshot
        XCTAssertFalse(doc.setParameters([DesignParameter(name:"width",expression:"-1in")]))
        XCTAssertEqual(doc.designSnapshot,before)
    }
    func testHistoryRestoresDesignWithoutRecursiveSnapshots() throws {
        let doc = document(), p = board(); doc.add(p)
        let entry = doc.studio.history!.last!
        doc.edit(p.id) { $0.size.x = 30 }
        XCTAssertGreaterThan(doc.studio.history!.count,1)
        doc.restoreHistory(entry)
        XCTAssertEqual(doc.part(p.id)?.size.x,20)
        doc.undo(); XCTAssertEqual(doc.part(p.id)?.size.x,30)
        let data = try JSONEncoder().encode(doc.project)
        XCTAssertLessThan(data.count,100_000)
    }
    func testFeatureSuppressionPreservesDefinitionButRemovesMachining() {
        var p = board(); p.cuts = [Cut(kind:"Dado",lo:SIMD3(2,0.5,0),hi:SIMD3(3,0.75,10),faceAxis:1,suppressed:true)]
        XCTAssertTrue(Flatten.flat(p).features.isEmpty)
        XCTAssertEqual(p.cuts.count,1)
    }
    func testParametricBookcaseResizesShelfAndDadosTogether() throws {
        let doc = document(); doc.insertParametricBookcase()
        XCTAssertEqual(doc.parts.count,6)
        XCTAssertNoThrow(try ModelValidation.validate(doc.project))
        let original = doc.parts.first { $0.name == "Shelf" }!.size.x
        var parameters = doc.studio.parameters!
        parameters[parameters.firstIndex { $0.name == "cabinet_width" }!].expression = "900mm"
        parameters[parameters.firstIndex { $0.name == "thickness" }!].expression = "21mm"
        XCTAssertTrue(doc.setParameters(parameters),doc.status)
        let shelf = doc.parts.first { $0.name == "Shelf" }!
        XCTAssertGreaterThan(shelf.size.x,original)
        XCTAssertEqual(shelf.size.y * 25.4,21,accuracy:1e-8)
        let side = doc.parts.first { $0.name == "Left side" }!
        XCTAssertEqual((side.cuts[0].hi.y - side.cuts[0].lo.y) * 25.4,21,accuracy:1e-8)
        XCTAssertTrue(doc.parts.map(Flatten.flat).flatMap(\.features).allSatisfy { $0.side != .bottom })
        XCTAssertNoThrow(try VCarveExport.artifacts(project:doc.project))
    }
    func testDirectEditsCannotSilentlyBreakExpressionsAndRotationPreservesSizeBinding() throws {
        let doc = document(),p = board(); doc.add(p)
        XCTAssertTrue(doc.setParameters([DesignParameter(name:"length",expression:"20in")]))
        doc.bind(DesignBinding(target:.size,axis:0,expression:"length"),to:p.id)
        doc.edit(p.id) { $0.size.x = 30 }
        XCTAssertEqual(doc.part(p.id)?.size.x,20)
        doc.rotateSelected(axis:1)
        XCTAssertEqual(doc.part(p.id)?.size.z,20)
        XCTAssertEqual(doc.part(p.id)?.bindings?.first?.axis,2)
        XCTAssertNoThrow(try ModelValidation.validate(doc.project))
    }
    func testCncDisplayDoesNotRoundAwayFitsOrBitSizes() {
        XCTAssertEqual(Units.format(0.25,metric:true),"6.35 mm")
        XCTAssertEqual(Units.format(0.15 / 25.4,metric:true),"0.15 mm")
        XCTAssertEqual(Units.format(0.065,metric:false),"0.065\"")
    }
    func testVCarveJobHasPerSheetOriginsMetadataAndSideSetups() throws {
        var p = board()
        p.operations = [MachiningOperation(name:"Bottom hole",axis:1,positive:false,depth:0.25,contour:MeshTools.circle(center:SIMD2(2,3),radius:0.125),kind:"Drill"),
            MachiningOperation(name:"End socket",axis:0,positive:true,depth:0.5,contour:[SIMD2(0.2,2),SIMD2(0.5,2),SIMD2(0.5,3),SIMD2(0.2,3)])]
        let artifacts = try VCarveExport.artifacts(project:Project(parts:[p],metric:true,sheetLength:24,sheetWidth:12))
        XCTAssertTrue(artifacts.contains { $0.name.hasSuffix("TOP.dxf") })
        XCTAssertTrue(artifacts.contains { $0.name.contains("BOTTOM-FLIP-LENGTH-AXIS") && $0.name.hasSuffix(".dxf") })
        XCTAssertTrue(artifacts.contains { $0.name.contains("SIDE +X UY VZ") })
        let json = try XCTUnwrap(artifacts.first { $0.name == "Setup and parameters.json" })
        let job = try JSONDecoder().decode(VCarveJob.self,from:json.data)
        XCTAssertEqual(job.vectorUnits,"millimeters")
        XCTAssertEqual(job.parts[0].operations?.count,2)
        XCTAssertEqual(job.placements[0].sheet,1)
        XCTAssertGreaterThanOrEqual(job.placements[0].xInches,0)
    }
}
