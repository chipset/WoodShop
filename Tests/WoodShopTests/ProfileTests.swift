import XCTest
import simd
@testable import WoodShop

final class ProfileTests: XCTestCase {
    private func board(_ preset: BoardProfile.Preset = .rounded) -> Part {
        var p = Part(name: "Curved board", origin: .zero, size: SIMD3(10, 0.75, 4), species: .oak)
        p.thicknessAxis = 1; p.grainDirection = 0
        p.profile = .preset(preset, part: p)
        return p
    }
    private func volume(_ polygons: [Geo.Poly]) -> Double {
        polygons.reduce(0) { sum, poly in
            sum + (1..<(poly.pts.count - 1)).reduce(0.0) { result, i in
                result + simd_dot(poly.pts[0], simd_cross(poly.pts[i], poly.pts[i + 1])) / 6
            }
        }
    }
    private func area(_ contours: [[SIMD2<Double>]]) -> Double { contours.reduce(0) { $0 + Planar.signedArea($1) } }

    func testPresetsHaveOutwardFacesAndExpectedExtrusionVolume() throws {
        for preset in BoardProfile.Preset.allCases {
            let p = board(preset), profile = try XCTUnwrap(p.profile)
            XCTAssertNil(ModelValidation.part(p), preset.rawValue)
            let polygons = Geo.polys(for: p)
            XCTAssertGreaterThan(polygons.count, 6)
            for polygon in polygons {
                XCTAssertTrue(polygon.pts.allSatisfy(ModelValidation.finite))
                XCTAssertEqual(simd_length(polygon.n), 1, accuracy: 1e-9)
                let cross = simd_cross(polygon.pts[1] - polygon.pts[0], polygon.pts[2] - polygon.pts[0])
                XCTAssertGreaterThan(simd_dot(cross, polygon.n), 0)
            }
            let expected = Planar.signedArea(profile.contour(size: p.size)) * p.size.y
            XCTAssertEqual(volume(polygons), expected, accuracy: 1e-8, preset.rawValue)
        }
        XCTAssertEqual(volume(Geo.polys(for: board(.oval))), .pi * 5 * 2 * 0.75, accuracy: 0.01)
        XCTAssertEqual(volume(Geo.polys(for: board(.rounded))), (40 - (4 - .pi) * 0.8 * 0.8) * 0.75, accuracy: 0.003)
    }

    func testConcaveRailSurvivesFlatteningRatherThanBecomingAHull() throws {
        let p = board(.rail), profile = try XCTUnwrap(p.profile)
        let contour = profile.contour(size: p.size), flat = Flatten.flat(p)
        XCTAssertEqual(flat.cutOutlines.count, 1)
        XCTAssertEqual(area(flat.cutOutlines), Planar.signedArea(contour), accuracy: 1e-8)
        XCTAssertLessThan(area(flat.cutOutlines), Planar.signedArea(Planar.hull(contour)) - 1)
        let projected = Flatten.projectedContours(Geo.polys(for: p), u: 0, v: 2)
        XCTAssertEqual(area(projected), area(flat.cutOutlines), accuracy: 1e-6)
    }

    func testCurvesSupportPocketsTenonsAndTrims() {
        var p = board()
        let originalVolume = volume(Geo.polys(for: p))
        p.cuts = [Cut(kind: "Mortise", lo: SIMD3(4, 0.5, 1), hi: SIMD3(6, 0.75, 3)),
                  Cut(kind: "Tenon", lo: SIMD3(-2, 0, 1), hi: SIMD3(0, 0.75, 3))]
        XCTAssertNil(ModelValidation.part(p))
        XCTAssertEqual(volume(Geo.polys(for: p)), originalVolume - 1 + 3, accuracy: 1e-6)
        XCTAssertEqual(area(Flatten.flat(p).cutOutlines), originalVolume / 0.75 + 4, accuracy: 1e-6)
        p.trims = [Trim(axis: 0, positive: false, run: 1, angle: 35, farEdge: false)]
        let trimmed = Geo.polys(for: p)
        XCTAssertGreaterThan(volume(trimmed), 0)
        XCTAssertLessThan(volume(trimmed), originalVolume)
        for point in trimmed.flatMap(\.pts) {
            for plane in p.trimPlanes { XCTAssertLessThanOrEqual(simd_dot(point - plane.p, plane.n), 1e-6) }
        }
        XCTAssertFalse(Flatten.flat(p).contours.isEmpty)
    }

    func testRotationPreservesProfileGeometryInAllPlanes() throws {
        let p = board(.rail), before = volume(Geo.polys(for: p))
        for axis in 0..<3 {
            var q = p
            for _ in 0..<4 {
                q = q.rotated90(axis: axis)
                XCTAssertNil(ModelValidation.part(q))
                XCTAssertEqual(volume(Geo.polys(for: q)), before, accuracy: 1e-7)
                XCTAssertEqual(area(Flatten.flat(q).cutOutlines), before / 0.75, accuracy: 1e-6)
            }
            let original = try XCTUnwrap(p.profile), rotated = try XCTUnwrap(q.profile)
            for (a, b) in zip(original.nodes, rotated.nodes) { XCTAssertLessThan(simd_length(a.point - b.point), 1e-12) }
        }
    }

    func testProfilePersistenceUndoResizeAndDuplicate() throws {
        let doc = Document(startRecoveryTimer: false)
        var p = board(); p.profile = nil
        doc.add(p)
        doc.selectedFace = FaceRef(part: p.id, axis: 0, positive: true)
        doc.edit(p.id) { $0.profile = .preset(.arch, part: $0) }
        XCTAssertNil(doc.selectedFace, "Changing the outline must clear a face that may no longer exist")
        let profile = doc.selectedPart?.profile
        doc.undo(); XCTAssertNil(doc.selectedPart?.profile)
        doc.redo(); XCTAssertEqual(doc.selectedPart?.profile, profile)
        doc.edit(p.id) { $0.size.x = 20 }
        XCTAssertEqual(doc.selectedPart?.profile, profile)
        XCTAssertEqual(Flatten.flat(doc.selectedPart!).footprint.hi.x, 20)
        doc.duplicateSelected()
        XCTAssertEqual(doc.selectedPart?.profile, profile)
        let project = try Document.decodeProject(JSONEncoder().encode(doc.project))
        XCTAssertEqual(project, doc.project)
        XCTAssertEqual(project.version, 6)
    }

    func testVersionOneProjectsRemainReadable() throws {
        var p = board(); p.profile = nil
        var project = Project(parts: [p]); project.version = 1
        let decoded = try Document.decodeProject(JSONEncoder().encode(project))
        XCTAssertNil(decoded.parts[0].profile)
    }

    func testInvalidOutlinesAreRejectedBeforeGeometry() throws {
        var p = board()
        p.profile!.u = 9
        XCTAssertNotNil(ModelValidation.part(p))
        XCTAssertThrowsError(try Document.decodeProject(JSONEncoder().encode(Project(parts: [p]))))
        p = board(); p.profile!.nodes[0].outgoing = SIMD2(2, 0)
        XCTAssertNotNil(ModelValidation.part(p))
        p.profile!.nodes = [.init(point: SIMD2(0, 0)), .init(point: SIMD2(1, 1)), .init(point: SIMD2(0, 1)), .init(point: SIMD2(1, 0))]
        XCTAssertNotNil(ModelValidation.part(p))
        p.profile!.nodes = [.init(point: SIMD2(0, 0)), .init(point: SIMD2(0.5, 0)), .init(point: SIMD2(1, 0))]
        XCTAssertNotNil(ModelValidation.part(p))
    }

    func testSplittingCurvePreservesItsShape() throws {
        let p = board(.oval)
        var profile = try XCTUnwrap(p.profile)
        let original = profile.contour(size: p.size)
        profile.split(after: profile.nodes.count - 1)
        XCTAssertNil(profile.validation(size: p.size))
        XCTAssertEqual(Planar.signedArea(original), Planar.signedArea(profile.contour(size: p.size)), accuracy: 1e-9)
    }

    func testCurvingAwayATenonAttachmentIsRejected() {
        var p = board(.oval)
        p.cuts = [Cut(kind: "Tenon", lo: SIMD3(-2, 0, 0), hi: SIMD3(0, 0.75, 1))]
        XCTAssertNotNil(ModelValidation.part(p))
        p.cuts[0].hi.x = 3 // overlapping real material connects the tenon
        XCTAssertNil(ModelValidation.part(p))
        p.cuts = [Cut(kind: "Tenon", lo: SIMD3(4, 0.75, 1), hi: SIMD3(6, 1.25, 3))]
        XCTAssertNil(ModelValidation.part(p))
    }

    func testCutListSeparatesDifferentProfilesAndExportsContainCurves() {
        let oval = board(.oval), rail = board(.rail)
        var plain = oval; plain.id = UUID(); plain.profile = nil
        XCTAssertEqual(CutList.rows([oval, rail, plain]).count, 3)
        XCTAssertTrue(CutList.rows([oval])[0].machining.contains("Curved"))
        let stl = Exporter3D.stl([rail], scale: 25.4)
        let triangles = stl.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        XCTAssertGreaterThan(triangles, 12)
        XCTAssertEqual(stl.count, 84 + Int(triangles) * 50)
        let nested = Nesting.nest([Flatten.flat(rail)], sheetL: 96, sheetW: 48, gap: 0.5)
        XCTAssertEqual(nested.placed.count, 1)
        let svg = CNCOut.svg(CNCOut.prims(nested, metric: true), sheetL: 96, sheetW: 48, count: 1, metric: true)
        XCTAssertTrue(XMLParser(data: Data(svg.utf8)).parse())
    }
}
