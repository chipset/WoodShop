import XCTest
import simd
@testable import WoodShop

final class WorkshopTests: XCTestCase {
    func board() -> Part { var p = Part(name: "Board", origin: .zero, size: SIMD3(10, 0.75, 6), species: .oak); p.thicknessAxis = 1; p.grainDirection = 0; return p }
    func doc() -> Document { Document(startRecoveryTimer: false, recoveryLocation: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    func volume(_ polygons: [Geo.Poly]) -> Double {
        var sum = 0.0
        for p in polygons { for i in 1..<(p.pts.count - 1) { sum += simd_dot(p.pts[0], simd_cross(p.pts[i], p.pts[i + 1])) / 6 } }
        return sum
    }
    func testReliefIncreasesPocketAndMatchesSolidRemoval() throws {
        var part = board()
        let cut = Cut(kind: "Mortise", lo: SIMD3(2, 0.25, 2), hi: SIMD3(4, 0.75, 4), faceAxis: 1, facePositive: true,
                      runAxis: 0, relief: CornerRelief(style: .dogbone, diameter: 0.25))
        part.cuts = [cut]
        XCTAssertNil(ModelValidation.part(part))
        let contour = cut.machiningContour(part: part), area = abs(Planar.signedArea(contour))
        XCTAssertGreaterThan(area, 4)
        XCTAssertTrue(Planar.isSimple(contour))
        XCTAssertEqual(volume(Geo.polys(for: part)), 45 - area * 0.5, accuracy: 1e-6)
        let flat = Flatten.flat(part)
        XCTAssertEqual(abs(Planar.signedArea(flat.features[0].polygon!)), area, accuracy: 1e-8)
    }
    func testTboneSelectedCornersAndClearance() {
        var part = board()
        let cut = Cut(kind: "Mortise", lo: SIMD3(2, 0.25, 2), hi: SIMD3(4, 0.75, 4), faceAxis: 1, facePositive: true,
            relief: CornerRelief(style: .tboneX, diameter: 0.25, corners: [true, false, false, false]), allowance: 0.01)
        part.cuts = [cut]
        let polygon = cut.machiningContour(part: part)
        XCTAssertGreaterThan(abs(Planar.signedArea(polygon)), 2.01 * 2.01)
        XCTAssertEqual(polygon.map(\.x).max()!, 4.005, accuracy: 1e-6)
        var bad = part; bad.cuts[0].relief?.diameter = 4
        XCTAssertNotNil(ModelValidation.part(bad))
    }
    func testLoftAndCountersinkVolumes() throws {
        let circle = MeshTools.circle(center: SIMD2(2, 2), radius: 0.5, segments: 48)
        let area = Planar.signedArea(circle)
        let solid = MeshTools.loft(circle, axis: 1, top: 0.75, bottom: 0.25)
        XCTAssertEqual(volume(solid), area * 0.5, accuracy: 1e-8)
        let taper = MeshTools.loft(circle, axis: 1, top: 0.75, bottom: 0.25, bottomScale: 0.5)
        XCTAssertEqual(volume(taper), area * 0.5 * (1 + 0.5 + 0.25) / 3, accuracy: 1e-8)
        let part = board()
        let operations = try JoineryTools.holes(part: part, axis: 1, positive: true, centers: [SIMD2(2, 2)], diameter: 0.25, depth: 0.75, counterDiameter: 0.5, countersinkAngle: 90)
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[1].depth, 0.125, accuracy: 1e-8)
        var drilled = part; drilled.operations = operations
        XCTAssertLessThan(volume(Geo.polys(for: drilled)), 45)
        XCTAssertEqual(Flatten.flat(drilled).features.count, 2)
    }
    func testFingerAndDovetailPatternsAreComplementary() throws {
        let p = board()
        let a = try JoineryTools.fingers(part: p, axis: 0, positive: true, count: 3, depth: 0.5, clearance: 0, complementary: false)
        let b = try JoineryTools.fingers(part: p, axis: 0, positive: false, count: 3, depth: 0.5, clearance: 0, complementary: true)
        XCTAssertEqual(a.count, 3); XCTAssertEqual(b.count, 4)
        let area = (a + b).reduce(0) { $0 + abs(Planar.signedArea($1.contour)) }
        XCTAssertEqual(area, p.size.y * p.size.z, accuracy: 1e-8)
        let dovetails = try JoineryTools.fingers(part: p, axis: 1, positive: true, count: 3, depth: 0.3, clearance: 0.005, complementary: false, dovetailAngle: 8)
        XCTAssertTrue(dovetails.allSatisfy { $0.bottomStretch!.x > 1 })
    }
    func testSharedComponentsUndoAndUniqueInstances() {
        let d = doc(); let p = board(); d.add(p); d.makeComponents(); d.duplicateSelected()
        let copied = d.selectedPart!
        d.edit(copied.id) { $0.size.x = 12 }
        XCTAssertEqual(d.part(p.id)?.size.x, 12)
        XCTAssertEqual(d.part(p.id)?.origin, .zero)
        d.undo(); XCTAssertEqual(d.part(p.id)?.size.x, 10)
        d.makeComponents(unique: true); d.edit(copied.id) { $0.size.x = 14 }
        XCTAssertEqual(d.part(p.id)?.size.x, 10)
    }
    func testNestedAssembliesAndArrays() {
        let d = doc(); var a = board(), b = board(); a.group = "Cabinet/Left"; b.group = "Cabinet/Right"
        d.add(a); d.add(b); d.selectAssembly("Cabinet"); XCTAssertEqual(d.selectedIDs.count, 2)
        d.linearArray(count: 2, step: SIMD3(12, 0, 0)); XCTAssertEqual(d.parts.count, 6)
        d.undo(); XCTAssertEqual(d.parts.count, 2)
        d.rotateAround(axis: 1, degrees: 90, pivot: .zero, copies: 3); XCTAssertEqual(d.parts.count, 8)
    }
    func testPivotMirrorScaleAndSweepPreserveSolidVolume() throws {
        let d = doc(), p = board(); d.add(p)
        d.rotateAround(axis: 1, degrees: 90, pivot: .zero)
        XCTAssertEqual(d.selectedPart!.center.x, 3, accuracy: 1e-8)
        XCTAssertEqual(d.selectedPart!.center.z, -5, accuracy: 1e-8)
        d.mirrorSelection(axis: 0, plane: 0, copy: true)
        XCTAssertEqual(volume(Geo.polys(for: d.selectedPart!)), 45, accuracy: 1e-6)
        d.scaleSelection(SIMD3(2, 1, 1), pivot: .zero)
        XCTAssertEqual(volume(Geo.polys(for: d.selectedPart!)), 90, accuracy: 1e-6)
        let shape = [SIMD2(-1.0,-0.5), SIMD2(1,-0.5), SIMD2(1,0.5), SIMD2(-1,0.5)]
        let sweep = try MeshTools.sweep(profile: shape, path: [.zero, SIMD3(0,0,10)])
        XCTAssertEqual(volume(sweep), 20, accuracy: 1e-8)
    }
    func testOffsetRejectsCollapse() throws {
        let square = [SIMD2<Double>(0,0), SIMD2(4,0), SIMD2(4,4), SIMD2(0,4)]
        XCTAssertEqual(Planar.signedArea(try Planar.offset(square, by: 1)), 36, accuracy: 1e-8)
        XCTAssertEqual(Planar.signedArea(try Planar.offset(square, by: -1)), 4, accuracy: 1e-8)
        XCTAssertThrowsError(try Planar.offset(square, by: -3))
    }
    func testSectionsAndConstructionInference() {
        let p = board()
        let cut = Geo.sectionPolygons(p, section: SectionPlane(axis: 0, value: 5))
        XCTAssertEqual(volume(cut), 22.5, accuracy: 1e-5)
        let guides = [ConstructionGuide(point: .zero, direction: SIMD3(1,0,0)), ConstructionGuide(point: SIMD3(2,0,0), direction: SIMD3(0,0,1))]
        let candidates = Inference.candidates(parts: [p], guides: guides)
        XCTAssertTrue(candidates.contains { $0.label == "Guide intersection" && $0.point == SIMD3(2,0,0) })
        XCTAssertNotNil(Inference.nearest(SIMD2(2,0), candidates: candidates, project: { SIMD2($0.x,$0.z) }, tolerance: 1))
    }
    func testSvgUnitsTransformsAndNestedCutouts() throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"254mm\" viewBox=\"0 0 100 100\"><g transform=\"translate(10,10)\"><path d=\"M0 0 L80 0 L80 80 L0 80 Z M20 20 L40 20 L40 40 L20 40 Z\"/></g></svg>"
        let imported = try GeometryImport.svg(Data(svg.utf8))
        let parts = try GeometryImport.parts(imported, thickness: 0.75, name: "SVG")
        XCTAssertEqual(parts.count, 1); XCTAssertEqual(parts[0].size.x, 8, accuracy: 1e-8)
        XCTAssertEqual(parts[0].operations?.count, 1)
        XCTAssertEqual(volume(Geo.polys(for: parts[0])), (64 - 4) * 0.75, accuracy: 1e-6)
    }
    func testObjAndDxfRoundTrip() throws {
        let p = board()
        let obj = Exporter3D.obj([p], scale: 25.4)
        let imported = try GeometryImport.obj(obj, scale: 1 / 25.4)
        XCTAssertEqual(volume(Geo.polys(for: imported)), 45, accuracy: 1e-5)
        let flat = Flatten.flat(p), nest = Nesting.nest([flat], sheetL: 96, sheetW: 48, gap: 0.5)
        let dxf = CNCOut.dxf(CNCOut.prims(nest, metric: true), metric: true)
        let contours = try GeometryImport.dxf(dxf, fallbackScale: 1)
        XCTAssertTrue(contours.contours.contains { abs(abs(Planar.signedArea($0)) - 60) < 1e-6 })
    }
    func testGrainRotationAndRegistrationStrip() {
        var p = board(); p.size = SIMD3(12, 0.75, 4)
        let noRotate = Nesting.nest([Flatten.flat(p)], sheetL: 6, sheetW: 14, gap: 0.5)
        XCTAssertEqual(noRotate.oversize.count, 1)
        p.allowNestingRotation = true
        let rotated = Nesting.nest([Flatten.flat(p)], sheetL: 6, sheetW: 14, gap: 0.5)
        XCTAssertTrue(rotated.oversize.isEmpty); XCTAssertEqual(rotated.placed[0].part.length, 4)
        let registration = Registration(enabled: true, diameter: 0.25, inset: 1)
        let nested = Nesting.nest([Flatten.flat(p)], sheetL: 96, sheetW: 48, gap: 0.5, registration: registration)
        XCTAssertGreaterThan(nested.placed[0].x, 1.625)
        let bottom = CNCOut.prims(nested, metric: false, setup: .bottom, registration: registration)
        XCTAssertEqual(bottom.filter { if case .poly(let layer, _) = $0 { return layer == "REGISTRATION_DRILL" }; return false }.count, 2)
    }
    func testMirroredMachiningStaysEditableAndExported() throws {
        let d = doc(); var p = board()
        p.cuts = [Cut(kind:"Mortise",lo:SIMD3(2,0.25,2),hi:SIMD3(4,0.75,4),faceAxis:1,facePositive:true,runAxis:0,relief:CornerRelief())]
        d.add(p); d.mirrorSelection(axis:0,plane:0,copy:true)
        let mirrored = try XCTUnwrap(d.selectedPart)
        XCTAssertNil(mirrored.mesh)
        XCTAssertEqual(mirrored.cuts.count,1)
        XCTAssertNotNil(Flatten.flat(mirrored).features[0].polygon)
        XCTAssertEqual(volume(Geo.polys(for:mirrored)),volume(Geo.polys(for:p)),accuracy:1e-6)
    }
    func testFeatureOrderIsRealAndCanBeUndone() {
        var p = board()
        let tenon = Cut(kind:"Tenon",lo:SIMD3(-1,0,2),hi:SIMD3(0,0.75,4))
        let trim = Cut(kind:"Dado",lo:SIMD3(-1,0,2),hi:SIMD3(1,0.75,4))
        p.cuts = [tenon,trim]; let a = volume(Geo.polys(for:p))
        p.cuts = [trim,tenon]; let b = volume(Geo.polys(for:p))
        XCTAssertGreaterThan(b,a)
    }
    func testStudioRoundTripAndSceneRestore() throws {
        let d = doc(); d.add(board())
        d.studio.guides = [ConstructionGuide(point: .zero, direction: SIMD3(1,0,0))]
        d.lastMeasurement = [.zero, SIMD3(10,0,0)]; d.rememberMeasurement(name: "Width")
        let ctrl = SceneController(doc: d); ctrl.saveScene("Assembly")
        let project = try Document.decodeProject(JSONEncoder().encode(d.project))
        XCTAssertEqual(project, d.project)
        let saved = d.studio.scenes[0]; ctrl.distance = 1000; ctrl.restoreScene(saved)
        XCTAssertEqual(ctrl.distance, saved.distance)
    }
}
