import XCTest
import simd
@testable import WoodShop

final class MergedFeatureTests: XCTestCase {
    private func volume(_ part: Part) -> Double {
        var v = 0.0
        for poly in Geo.polys(for: part) {
            for i in 1..<(poly.pts.count - 1) { v += simd_dot(poly.pts[0], simd_cross(poly.pts[i], poly.pts[i + 1])) / 6.0 }
        }
        return v
    }
    private func board(_ name: String, _ l: Double, _ w: Double = 3.5, _ t: Double = 0.75, species: Species = .oak) -> Part {
        var p = Part(name: name, origin: .zero, size: SIMD3(l, t, w), species: species)
        p.thicknessAxis = 1; p.grainDirection = 0
        return p
    }
    private func document() -> Document {
        Document(startRecoveryTimer: false, recoveryLocation: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    // MARK: Geometry

    func testPocketHoleRemovesMaterialInsideTheBoard() {
        var p = board("P", 12, 3, 0.75)
        let face = FaceRef(part: p.id, axis: 1, positive: false)
        p.cuts = [JoineryGen.pocketHole(part: p, face: face, run: 0, towardPositiveEnd: false, entry: SIMD2(1.5, 1.5))]
        let removed = 27 - volume(p)
        XCTAssertGreaterThan(removed, 0.12)
        XCTAssertLessThan(removed, 0.25)
        XCTAssertNil(ModelValidation.part(p))
        XCTAssertNoThrow(try FeatureReplay.validate(p))
    }

    func testChamferRoundoverAndArch() {
        var p = board("E", 4, 2, 1)
        p.edges = [EdgeProfile(kind: .chamfer, axis1: 1, pos1: true, axis2: 0, pos2: true, size: 0.5)]
        XCTAssertEqual(volume(p), 8 - 0.5 * 0.5 * 0.5 * 2, accuracy: 1e-9)
        p.edges = [EdgeProfile(kind: .roundover, axis1: 1, pos1: true, axis2: 0, pos2: true, size: 0.5)]
        let ideal = 0.25 * (1 - .pi / 4) * 2
        XCTAssertEqual(8 - volume(p), ideal, accuracy: ideal * 0.12)
        var panel = board("Arch", 6, 0.75, 12)
        panel.thicknessAxis = 2; panel.grainDirection = 1
        panel.size = SIMD3(6, 12, 0.75)
        panel.edges = [EdgeProfile(kind: .arch, axis1: 1, pos1: true, axis2: 0, pos2: true, size: 2)]
        let W = 6.0, h = 2.0, R = (h * h + W * W / 4) / (2 * h)
        let segment = R * R * acos((R - h) / R) - (R - h) * (2 * R * h - h * h).squareRoot()
        let removed = (W * h - segment) * 0.75
        XCTAssertEqual(54 - volume(panel), removed, accuracy: removed * 0.06)
    }

    func testEdgeProfileCombinesWithOtherFeatures() {
        // Edge profile on a board that already uses the original CSG path (a curved outline plus a pocket).
        var p = board("Mixed", 8, 4, 1)
        p.cuts = [Cut(kind: "Pocket", lo: SIMD3(2, 0.5, 1), hi: SIMD3(4, 1, 3), faceAxis: 1, facePositive: true, runAxis: 0)]
        let base = volume(p)
        p.edges = [EdgeProfile(kind: .chamfer, axis1: 1, pos1: true, axis2: 0, pos2: true, size: 0.25)]
        XCTAssertEqual(base - volume(p), 0.25 * 0.25 / 2 * 4, accuracy: 1e-9)
        // And the same through the feature-history path.
        p.featureOrder = p.featureSteps
        XCTAssertEqual(base - volume(p), 0.25 * 0.25 / 2 * 4, accuracy: 1e-9)
    }

    func testGeneratedShapesSurviveRotationAndResize() {
        var p = board("R", 6, 4, 1)
        p.cuts = [JoineryGen.pocketHole(part: p, face: FaceRef(part: p.id, axis: 1, positive: true), run: 0, towardPositiveEnd: true, entry: SIMD2(4, 2))]
        p.edges = [EdgeProfile(kind: .roundover, axis1: 1, pos1: true, axis2: 2, pos2: true, size: 0.25)]
        let before = volume(p)
        let turned = p.rotated90(axis: 0)
        XCTAssertEqual(volume(turned), before, accuracy: 1e-6)
        XCTAssertNil(ModelValidation.part(turned))
        var twice = turned.rotated90(axis: 0)
        XCTAssertEqual(volume(twice), before, accuracy: 1e-6)
        twice.size.y = 2
        XCTAssertNil(ModelValidation.part(twice))
    }

    func testOlderProjectsStillDecode() throws {
        let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Old","origin":[0,0,0],"size":[1,1,1],"species":"Cherry"}"#
        let p = try JSONDecoder().decode(Part.self, from: Data(legacy.utf8))
        XCTAssertNil(p.edges)
    }

    func testProjectRoundTripKeepsEdgesAndPlanes() throws {
        var p = board("Panel", 10)
        p.edges = [EdgeProfile(kind: .roundover, axis1: 1, pos1: true, axis2: 0, pos2: true, size: 0.25)]
        p.cuts = [JoineryGen.pocketHole(part: p, face: FaceRef(part: p.id, axis: 1, positive: false), run: 0, towardPositiveEnd: true, entry: SIMD2(8, 1.5))]
        let data = try JSONEncoder().encode(Project(parts: [p]))
        let back = try Document.decodeProject(data)
        XCTAssertEqual(back.parts[0], p)
        XCTAssertNotNil(back.parts[0].cuts[0].planes)
    }

    // MARK: Export, cut list, validation

    func testPocketHoleAppearsInTheFlatExportAsAnOpening() throws {
        var p = board("Pocket board", 10, 4, 0.75)
        p.cuts = [JoineryGen.pocketHole(part: p, face: FaceRef(part: p.id, axis: 1, positive: false), run: 0, towardPositiveEnd: false, entry: SIMD2(1.5, 2))]
        let flat = Flatten.flat(p)
        let f = try XCTUnwrap(flat.features.first)
        XCTAssertNotNil(f.polygon)
        XCTAssertTrue(flat.notes.contains { $0.contains("pocket holes") })
    }

    func testEdgeProfilesChangeTheCutListGrouping() {
        let a = board("A", 10, 3, 0.75)
        var b = a; b.id = UUID(); b.name = "B"
        b.edges = [EdgeProfile(kind: .chamfer, axis1: 1, pos1: true, axis2: 0, pos2: true, size: 0.25)]
        XCTAssertEqual(CutList.rows([a, b]).count, 2)
        var c = a; c.id = UUID(); c.name = "C"
        XCTAssertEqual(CutList.rows([a, c]).count, 1)
    }

    func testValidationRejectsCorruptEdgeProfilesAndPlanes() {
        var p = board("A", 10, 3, 1)
        p.edges = [EdgeProfile(kind: .roundover, axis1: 5, pos1: true, axis2: 0, pos2: true, size: 0.25)]
        XCTAssertNotNil(ModelValidation.part(p))
        p.edges = [EdgeProfile(kind: .roundover, axis1: 1, pos1: true, axis2: 1, pos2: true, size: 0.25)]
        XCTAssertNotNil(ModelValidation.part(p))
        p.edges = [EdgeProfile(kind: .roundover, axis1: 1, pos1: true, axis2: 0, pos2: true, size: .nan)]
        XCTAssertNotNil(ModelValidation.part(p))
        p.edges = nil
        p.cuts = [Cut(kind: "Hole", lo: SIMD3(1, 0, 1), hi: SIMD3(2, 1, 2), planes: [Plane(p: .zero, n: SIMD3(.nan, 0, 0))])]
        XCTAssertNotNil(ModelValidation.part(p))
    }

    // MARK: Buying

    func testRoughThicknessQuarters() {
        XCTAssertEqual(Buying.quarters(forFinished: 0.75), 4)
        XCTAssertEqual(Buying.quarters(forFinished: 0.875), 4)
        XCTAssertEqual(Buying.quarters(forFinished: 1.0), 5)
        XCTAssertEqual(Buying.quarters(forFinished: 1.75), 8)
    }

    func testRoughBoardFeetIncludeAllowanceAndWaste() {
        let h = Buying.hardwood(CutList.rows([board("A", 24), board("B", 24)]), waste: 0.15)
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h[0].roughBF, 2 * 1.0 * 3.75 * 25 / 144 * 1.15, accuracy: 1e-9)
    }

    func testCutPlanPacksBoardsWithKerfAndKeepsOverlongPartsAlone() {
        let boards = Buying.plan(CutList.rows([board("A", 60), board("B", 30), board("C", 30), board("D", 40)]), stockLength: 96, kerf: 0.125)
        XCTAssertEqual(boards.count, 2)
        XCTAssertEqual(boards.flatMap(\.pieces).sorted(), [30, 30, 40, 60])
        XCTAssertTrue(boards.allSatisfy { $0.used <= $0.length + 1e-9 })
        let long = Buying.plan(CutList.rows([board("Long", 120)]), stockLength: 96, kerf: 0.125)
        XCTAssertEqual(long.map(\.length), [120])
    }

    func testHardwareStockIsListedAndExcludedFromLumberAndCNC() {
        let d = document()
        d.stock = Stock.all.first { $0.name.hasPrefix("Hinge") }!
        d.addStock(); d.addStock()
        d.stock = Stock.all[2]
        d.addStock()
        XCTAssertEqual(d.parts.filter { $0.hardware == true }.count, 2)
        XCTAssertTrue(d.parts.filter { $0.hardware == true }.allSatisfy { $0.species == .brass })
        XCTAssertEqual(Buying.hardware(d.parts).first?.qty, 2)
        XCTAssertEqual(Buying.hardwood(CutList.rows(d.parts), waste: 0).count, 1)
        XCTAssertEqual(CutList.rows(d.parts).reduce(0) { $0 + $1.qty }, 1)
        XCTAssertNil(ModelValidation.part(d.parts[0]))
        XCTAssertFalse(Species.woods.contains(.steel))
        let csv = Buying.csv(parts: d.parts, stockLength: 96, kerf: 0.125, waste: 0.15, metric: false, sheetL: 96, sheetW: 48, gap: 0.5)
        XCTAssertTrue(csv.contains("Hinge 3in butt"))
    }

    func testSheetCountsUseTheSheetPartsOnly() {
        let sheets = Buying.sheets([board("Side", 40, 20, 0.75, species: .plywood), board("Rail", 30)], sheetL: 96, sheetW: 48, gap: 0.5)
        XCTAssertEqual(sheets.map(\.sheets), [1])
    }

    // MARK: Workflow

    func testCopyCutPasteAndSelectAll() {
        let d = document()
        d.parts = [board("A", 10), board("B", 10)]
        d.select(d.parts[0].id)
        d.copyBoards()
        d.pasteBoards()
        XCTAssertEqual(d.parts.count, 3)
        XCTAssertEqual(Set(d.parts.map(\.id)).count, 3)
        XCTAssertEqual(d.selectedIDs.count, 1)
        XCTAssertNotEqual(d.parts[2].origin, d.parts[0].origin)
        d.pasteBoards()
        XCTAssertEqual(d.parts.count, 4)
        XCTAssertNotEqual(d.parts[3].origin, d.parts[2].origin)
        d.cutBoards()
        XCTAssertEqual(d.parts.count, 3)
        d.pasteBoards()
        XCTAssertEqual(d.parts.count, 4)
        d.parts[0].hidden = true
        d.selectAllBoards()
        XCTAssertEqual(d.selectedIDs.count, 3)
        d.undo()
        XCTAssertNoThrow(try ModelValidation.validate(d.project))
    }

    func testPasteDropsMatedJoineryAndKeepsNumbersUnique() {
        let d = document()
        var p = board("A", 10)
        p.cuts = [Cut(kind: "Dado", lo: SIMD3(1, 0.4, 0), hi: SIMD3(2, 0.75, 3.5), faceAxis: 1, facePositive: true, runAxis: 2, mateID: UUID())]
        d.parts = [p]
        d.select(p.id)
        d.copyBoards(); d.pasteBoards()
        XCTAssertEqual(d.parts.count, 2)
        XCTAssertTrue(d.parts[1].cuts.isEmpty)
        XCTAssertNil(ModelValidation.part(d.parts[1]))
    }

    func testWoodMovementCoefficients() {
        XCTAssertGreaterThan(Species.maple.movementPerPercentMC, Species.cherry.movementPerPercentMC)
        XCTAssertEqual(Species.plywood.movementPerPercentMC, 0)
        XCTAssertTrue(Species.brass.isHardware)
    }

    func testRecentFilesKeepNewestFirstAndDropMissingFiles() throws {
        Recents.clear()
        defer { Recents.clear() }
        // Scratch files in the temp directory are deliberately not remembered.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wood")
        try Data("{}".utf8).write(to: scratch)
        Recents.add(scratch)
        XCTAssertTrue(Recents.urls.isEmpty)
        // Anything else is (home directory stands in for a real project folder).
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/WoodShopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.wood"), b = dir.appendingPathComponent("b.wood")
        try Data("{}".utf8).write(to: a); try Data("{}".utf8).write(to: b)
        Recents.add(a); Recents.add(b); Recents.add(a)
        XCTAssertEqual(Recents.urls.map(\.lastPathComponent), ["a.wood", "b.wood"])
        try FileManager.default.removeItem(at: b)
        XCTAssertEqual(Recents.urls.map(\.lastPathComponent), ["a.wood"])
    }
}
