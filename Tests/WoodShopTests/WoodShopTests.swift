import XCTest
import simd
@testable import WoodShop

final class WoodShopTests: XCTestCase {
    private func board(_ name: String = "Board", length: Double = 10) -> Part {
        var p = Part(name: name, origin: .zero, size: SIMD3(length, 0.75, 4), species: .oak)
        p.thicknessAxis = 1; p.grainDirection = 0
        return p
    }
    private func document() -> Document { Document(startRecoveryTimer: false, recoveryLocation: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")) }
    private func area(_ polygons: [[SIMD2<Double>]]) -> Double {
        polygons.reduce(0) { sum, polygon in
            sum + polygon.indices.reduce(0) { $0 + Planar.cross(polygon[$1], polygon[($1 + 1) % polygon.count]) } / 2
        }
    }
    private func volume(_ part: Part) -> Double {
        var result = 0.0
        for poly in Geo.polys(for: part) {
            for i in 1..<(poly.pts.count - 1) {
                result += simd_dot(poly.pts[0], simd_cross(poly.pts[i], poly.pts[i + 1])) / 6.0
            }
        }
        return result
    }

    func testMeasurementParsingAndFormatting() {
        let examples: [(String, Double)] = [("3 1/2", 3.5), ("3-1/2\"", 3.5), ("-1/4", -0.25), ("2' 3", 27), ("25.4mm", 1), ("2.54cm", 1)]
        for (text, expected) in examples { XCTAssertEqual(Units.parse(text) ?? .nan, expected, accuracy: 1e-9, text) }
        XCTAssertEqual(Units.parse("25.4", bareIsMM: true) ?? .nan, 1, accuracy: 1e-9)
        XCTAssertEqual(Units.format(3.5, metric: false), "3 1/2\"")
        XCTAssertEqual(Units.format(1, metric: true), "25.4 mm")
    }
    func testRejectsNonfiniteMeasurements() {
        for input in ["nan", "inf", "-inf", "1e999", "1/0", "abc", ""] { XCTAssertNil(Units.parse(input), input) }
        XCTAssertEqual(Units.format(.infinity, metric: false), "Invalid")
        XCTAssertEqual(Units.format(.nan, metric: true), "Invalid")
    }
    func testProjectRoundTripIncludesSettingsAndIntent() throws {
        var p = board(); p.group = "Case"; p.hidden = true; p.resizeJoinery = true
        var project = Project(parts: [p], metric: true)
        project.snap = 1 / 25.4; project.sheetLength = 60; project.nestGap = 0.25
        let decoded = try Document.decodeProject(JSONEncoder().encode(project))
        XCTAssertEqual(decoded, project)
    }
    func testLegacyProjectLoadsWithDefaults() throws {
        let p = board()
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([p])) as? [[String: Any]])
        for key in ["rot", "trims", "cuts", "thicknessAxis", "grainDirection"] { objects[0].removeValue(forKey: key) }
        let project = try Document.decodeProject(JSONSerialization.data(withJSONObject: objects))
        XCTAssertEqual(project.parts.count, 1)
        XCTAssertEqual(project.parts[0].rot, .zero)
        XCTAssertTrue(project.parts[0].cuts.isEmpty)
        XCTAssertFalse(project.metric)
    }
    func testRejectsMalformedProjectsBeforeGeometry() throws {
        var p = board(); p.trims = [Trim(axis: 7, positive: true, run: 0, angle: 45, farEdge: false)]
        XCTAssertThrowsError(try Document.decodeProject(JSONEncoder().encode(Project(parts: [p]))))
        p = board(); p.size.y = -1
        XCTAssertThrowsError(try ModelValidation.validate(Project(parts: [p])))
        XCTAssertNoThrow(try ModelValidation.validate(Project(parts: [board(), board()])))
    }
    func testRejectsDuplicateIdentifiersAndUnsupportedVersions() {
        let p = board()
        XCTAssertThrowsError(try ModelValidation.validate(Project(parts: [p, p])))
        var project = Project(); project.version = 99
        XCTAssertThrowsError(try ModelValidation.validate(project))
    }
    func testSaveIsReadableAndMarksOnlySuccessfulSavesClean() throws {
        let doc = document(); doc.add(board())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.wood")
        XCTAssertTrue(doc.isDirty)
        try doc.writeProject(to: url)
        XCTAssertEqual(try Document.decodeProject(Data(contentsOf: url)), doc.project)
        XCTAssertFalse(doc.isDirty)
        doc.edit(doc.parts[0].id) { $0.name = "Changed" }
        XCTAssertTrue(doc.isDirty)
        XCTAssertThrowsError(try doc.writeProject(to: dir.appendingPathComponent("missing/file.wood")))
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try Document.decodeProject(Data(contentsOf: url)).parts[0].name, "Board")
    }
    func testRecoveryStoresProjectAndClearsWhenUndoReturnsToSavedState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = Document(startRecoveryTimer: false, recoveryLocation: url)
        doc.add(board()); doc.autosaveRecovery()
        let recovery = try JSONDecoder().decode(Document.Recovery.self, from: Data(contentsOf: url))
        XCTAssertEqual(recovery.project, doc.project)
        doc.undo(); doc.autosaveRecovery()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testCanceledEditRestoresWholeLinkedAssemblyAndRedo() {
        let doc = document(), a = board("Source"), b = board("Target")
        doc.add(a); doc.add(b)
        doc.addLink(DimensionLink(source: a.id, sourceAxis: 0, target: b.id, targetAxis: 0, offset: -1))
        let initialDesign = doc.designSnapshot
        doc.edit(a.id) { $0.origin.x = 7 }; doc.undo()
        XCTAssertEqual(doc.designSnapshot, initialDesign)
        let original = doc.project
        XCTAssertTrue(doc.canRedo)
        doc.checkpoint(); doc.update(a.id) { $0.size.x = 20 }; doc.cancelCheckpoint()
        XCTAssertEqual(doc.project, original)
        XCTAssertTrue(doc.canRedo)
        doc.redo(); XCTAssertEqual(doc.part(a.id)?.origin.x, 7)
    }
    func testClickWithoutDragKeepsRedoHistory() {
        let doc = document(); let p = board()
        doc.add(p); doc.edit(p.id) { $0.origin.x = 4 }; doc.undo()
        doc.checkpoint(); doc.discardCheckpointIfUnchanged()
        XCTAssertTrue(doc.canRedo)
        doc.redo(); XCTAssertEqual(doc.selectedPart?.origin.x, 4)
    }
    func testRotationPreservesTrimPlanesAndJoinery() {
        for axis in 0..<3 {
            for faceAxis in 0..<3 {
                for run in (0..<3).filter({ $0 != faceAxis }) {
                    for positive in [false, true] {
                        for far in [false, true] {
                            var p = board()
                            p.trims = [Trim(axis: faceAxis, positive: positive, run: run, angle: 35, farEdge: far)]
                            p.cuts = [Cut(kind: "Dado", lo: SIMD3(2, 0.5, 0), hi: SIMD3(3, 0.75, 4))]
                            let q = p.rotated90(axis: axis)
                            XCTAssertEqual(q.trims.count, 1)
                            XCTAssertEqual(q.cuts.count, 1)
                            let a = (axis + 1) % 3, b = (axis + 2) % 3
                            let oldPlane = p.trimPlanes[0], newPlane = q.trimPlanes[0]
                            var expectedN = oldPlane.n
                            expectedN[a] = -oldPlane.n[b]; expectedN[b] = oldPlane.n[a]
                            XCTAssertLessThan(simd_length(expectedN - newPlane.n), 1e-9)
                            var expectedP = oldPlane.p
                            expectedP[a] = p.size[b] - oldPlane.p[b]; expectedP[b] = oldPlane.p[a]
                            XCTAssertEqual(simd_dot(expectedP - newPlane.p, newPlane.n), 0, accuracy: 1e-9)
                            XCTAssertEqual(volume(q), volume(p), accuracy: 1e-5)
                        }
                    }
                }
            }
        }
    }
    func testMaterialIntentSurvivesResizing() {
        let doc = document(); var p = board()
        p.cuts = [Cut(kind: "Dado", lo: SIMD3(2, 0.5, 0), hi: SIMD3(3, 0.75, 4))]
        p.resizeJoinery = true; doc.add(p)
        doc.edit(p.id) { $0.size.x = 2 }
        XCTAssertEqual(doc.selectedPart?.materialAxes.t, 1)
        XCTAssertEqual(doc.selectedPart?.materialAxes.l, 0)
        XCTAssertEqual(doc.selectedPart?.cuts[0].lo.x ?? .nan, 0.4, accuracy: 1e-9)
        XCTAssertEqual(Flatten.flat(doc.selectedPart!).length, 2)
        doc.undo(); XCTAssertEqual(doc.selectedPart?.size.x, 10)
    }
    func testLinkedDimensionsPropagateAndUndoAsOneChange() {
        let doc = document(), a = board("A"), b = board("B"), c = board("C")
        doc.add(a); doc.add(b); doc.add(c)
        doc.addLink(DimensionLink(source: a.id, sourceAxis: 0, target: b.id, targetAxis: 0, offset: -1))
        doc.addLink(DimensionLink(source: b.id, sourceAxis: 0, target: c.id, targetAxis: 0, offset: -2))
        doc.edit(a.id) { $0.size.x = 20 }
        XCTAssertEqual(doc.part(b.id)?.size.x, 19); XCTAssertEqual(doc.part(c.id)?.size.x, 17)
        doc.undo(); XCTAssertEqual(doc.part(c.id)?.size.x, 7)
        let count = doc.links.count
        doc.addLink(DimensionLink(source: c.id, sourceAxis: 0, target: a.id, targetAxis: 0))
        XCTAssertEqual(doc.links.count, count)
        doc.edit(a.id) { $0.size.x = 2 }
        XCTAssertEqual(doc.part(a.id)?.size.x, 10)
        XCTAssertEqual(doc.part(c.id)?.size.x, 7)
    }
    func testBranchingDimensionLinksUseDependencyOrder() {
        let doc = document(), a = board("A"), b = board("B"), c = board("C"), d = board("D")
        for p in [a, b, c, d] { doc.add(p) }
        doc.addLink(DimensionLink(source: a.id, sourceAxis: 0, target: b.id, targetAxis: 0, offset: -1))
        doc.addLink(DimensionLink(source: a.id, sourceAxis: 0, target: c.id, targetAxis: 0, offset: -2))
        doc.addLink(DimensionLink(source: c.id, sourceAxis: 0, target: b.id, targetAxis: 2))
        doc.addLink(DimensionLink(source: b.id, sourceAxis: 2, target: d.id, targetAxis: 0))
        doc.edit(a.id) { $0.size.x = 30 }
        XCTAssertEqual(doc.part(d.id)?.size.x, 28)
    }
    func testMultipleSelectionAlignmentDeleteAndUndo() {
        let doc = document(); var a = board("A"), b = board("B")
        a.origin.x = 12; b.origin.x = 3
        doc.add(a); doc.add(b); doc.select(a.id); doc.select(b.id, extending: true)
        XCTAssertEqual(doc.selectedIDs.count, 2)
        doc.alignSelected(axis: 0)
        XCTAssertEqual(doc.part(a.id)?.origin.x, 3)
        doc.setGroup("Case"); XCTAssertEqual(doc.parts.map { $0.group }, ["Case", "Case"])
        doc.deleteSelected(); XCTAssertTrue(doc.parts.isEmpty)
        doc.undo(); XCTAssertEqual(doc.parts.count, 2)
    }
    func testCutListSeparatesDifferentMachiningAndKeepsMetricPrecision() {
        let a = board("Plain"), b = board("Same blank")
        var c = board("Dadoed")
        c.cuts = [Cut(kind: "Dado", lo: SIMD3(2, 0.5, 0), hi: SIMD3(3, 0.75, 4))]
        let rows = CutList.rows([a, b, c])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.qty).sorted(), [1, 2])
        XCTAssertEqual(CutList.rows([board(length: 10.001), board(length: 10.002)]).count, 2)
    }
    func testCSVQuotesInchMarksCommasAndNames() {
        let p = board("Side, \"A\"", length: 3.5)
        let csv = CutList.csv(CutList.rows([p]), metric: false)
        XCTAssertEqual(csv, "Qty,Species,Thickness,Width,Length,Board Feet,Parts,Machining,Part IDs\r\n\"1\",\"Red Oak\",\"3/4\"\"\",\"4\"\"\",\"3 1/2\"\"\",\"0.07\",\"Side, \"\"A\"\"\",\"\",\"\(ShopIdentity.label(p))\"\r\n")
    }
    func testUnionMergesConcaveTenonOutline() {
        var p = board()
        p.cuts = [Cut(kind: "Tenon", lo: SIMD3(-2, 0, 1), hi: SIMD3(0, 0.75, 3))]
        let flat = Flatten.flat(p)
        XCTAssertEqual(flat.cutOutlines.count, 1)
        XCTAssertGreaterThan(flat.cutOutlines[0].count, 4)
        XCTAssertEqual(area(flat.cutOutlines), 44, accuracy: 1e-6)
        XCTAssertEqual(flat.footprint.lo.x, -2)
        XCTAssertEqual(volume(p), 33, accuracy: 1e-6)
    }
    func testOverlappingTenonsDoNotDuplicateMaterialOrOutline() {
        var p = board()
        p.cuts = [Cut(kind: "Tenon", lo: SIMD3(-2, 0, 1), hi: SIMD3(0, 0.75, 3)),
                  Cut(kind: "Tenon", lo: SIMD3(-1, 0, 1), hi: SIMD3(0, 0.75, 3))]
        XCTAssertEqual(volume(p), 33, accuracy: 1e-6)
        XCTAssertEqual(area(Flatten.flat(p).cutOutlines), 44, accuracy: 1e-6)
    }
    func testNestingUsesFullTenonFootprint() {
        var p = board()
        p.cuts = [Cut(kind: "Tenon", lo: SIMD3(-2, 0, 1), hi: SIMD3(0, 0.75, 3))]
        let flat = Flatten.flat(p)
        let fit = Nesting.nest([flat], sheetL: 13, sheetW: 5, gap: 0.5)
        XCTAssertTrue(fit.oversize.isEmpty)
        XCTAssertEqual(fit.placed.count, 1)
        XCTAssertEqual(fit.placed[0].x + flat.footprint.lo.x, 0.5, accuracy: 1e-9)
        let noFit = Nesting.nest([flat], sheetL: 12.9, sheetW: 5, gap: 0.5)
        XCTAssertEqual(noFit.oversize, [p.name]); XCTAssertTrue(noFit.placed.isEmpty)
    }
    func testNestingRespectsSheetEdgesAndMaterialGroups() {
        let flat = [board("A"), board("B"), board("C")].map(Flatten.flat)
        let result = Nesting.nest(flat, sheetL: 22, sheetW: 10, gap: 0.5)
        XCTAssertTrue(result.oversize.isEmpty)
        for placed in result.placed {
            let sheet = result.sheets[placed.sheet]
            let bounds = placed.part.footprint
            XCTAssertGreaterThanOrEqual(placed.x + bounds.lo.x - sheet.x, 0.5 - 1e-9)
            XCTAssertLessThanOrEqual(placed.x + bounds.hi.x - sheet.x, 21.5 + 1e-9)
            XCTAssertLessThanOrEqual(placed.y + bounds.hi.y, 9.5 + 1e-9)
        }
        var thin = board(); thin.size.y = 0.75001
        var thick = board(); thick.size.y = 0.75002
        XCTAssertEqual(Nesting.nest([Flatten.flat(thin), Flatten.flat(thick)], sheetL: 96, sheetW: 48, gap: 0.5).sheets.count, 2)
    }
    func testNestingRejectsInvalidSettings() {
        for settings in [(0.0, 48.0, 0.5), (96, -48, 0.5), (96, 48, -1), (96, 48, 30), (Double.nan, 48, 0.5)] {
            XCTAssertNotNil(ModelValidation.nesting(sheetL: settings.0, sheetW: settings.1, gap: settings.2))
            XCTAssertTrue(Nesting.nest([Flatten.flat(board())], sheetL: settings.0, sheetW: settings.1, gap: settings.2).placed.isEmpty)
        }
    }
    func testSVGLabelsProduceValidXMLAndUniqueIDs() {
        let primitives: [Prim] = [.text(layer: "LABELS", at: .zero, size: 1, string: "A & B <left> \"oak\""),
                                  .poly(layer: "OUTLINE", pts: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1)]),
                                  .poly(layer: "OUTLINE", pts: [SIMD2(2, 0), SIMD2(3, 0), SIMD2(3, 1)])]
        let svg = CNCOut.svg(primitives, sheetL: 96, sheetW: 48, count: 1, metric: true)
        XCTAssertTrue(XMLParser(data: Data(svg.utf8)).parse())
        XCTAssertTrue(svg.contains("A &amp; B &lt;left&gt; &quot;oak&quot;"))
        XCTAssertTrue(svg.contains("id=\"OUTLINE-1\"")); XCTAssertTrue(svg.contains("id=\"OUTLINE-2\""))
    }
    func testSTLIncludesExpectedUnitsAndTriangleCount() {
        let data = Exporter3D.stl([board()], scale: 25.4)
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        XCTAssertEqual(count, 12)
        XCTAssertEqual(data.count, 84 + Int(count) * 50)
        var xs: [Float] = []
        for i in 0..<Int(count) {
            for v in 0..<3 { xs.append(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 84 + i * 50 + 12 + v * 12, as: Float.self) }) }
        }
        XCTAssertEqual(xs.max()!, 254, accuracy: 0.001)
    }
    func testFixedJointDepthRemainsAnchoredToItsFaceWhenResizing() {
        let doc = document(); var p = board()
        p.cuts = [Cut(kind: "Dado", lo: SIMD3(2, 0.5, 0), hi: SIMD3(3, 0.75, 4), faceAxis: 1, facePositive: true, runAxis: 2)]
        doc.add(p)
        doc.edit(p.id) { $0.size.y = 1 }
        XCTAssertEqual(doc.selectedPart?.cuts[0].lo.y, 0.75)
        XCTAssertEqual(doc.selectedPart?.cuts[0].hi.y, 1)
        doc.undo(); XCTAssertEqual(doc.selectedPart?.cuts[0].lo.y, 0.5)
    }
    func testDuplicatedAssemblyRetainsIndependentRelationships() {
        let doc = document(), a = board("A"), b = board("B")
        doc.add(a); doc.add(b)
        doc.addLink(DimensionLink(source: a.id, sourceAxis: 0, target: b.id, targetAxis: 0, offset: -1))
        doc.select(a.id); doc.select(b.id, extending: true); doc.duplicateSelected()
        let copiedSource = doc.parts.first { $0.name == "A copy" }!
        let copiedTarget = doc.parts.first { $0.name == "B copy" }!
        doc.edit(copiedSource.id) { $0.size.x = 20 }
        XCTAssertEqual(doc.part(copiedTarget.id)?.size.x, 19)
        XCTAssertEqual(doc.part(b.id)?.size.x, 9)
        XCTAssertNoThrow(try ModelValidation.validate(doc.project))
    }
    func testCutListBlankIncludesTenonExtensions() {
        var p = board()
        p.cuts = [Cut(kind: "Tenon", lo: SIMD3(-2, 0, 1), hi: SIMD3(0, 0.75, 3))]
        let row = CutList.rows([p])[0]
        XCTAssertEqual(row.l, 12)
        XCTAssertEqual(row.boardFeet, 0.25, accuracy: 1e-9)
    }
    func testRejectsDisconnectedTenonsAndInvalidJointAxes() {
        var p = board()
        p.cuts = [Cut(kind: "Tenon", lo: SIMD3(-3, 0, 1), hi: SIMD3(-2, 0.75, 3))]
        XCTAssertNotNil(ModelValidation.part(p))
        p.cuts = [Cut(kind: "Dado", lo: .zero, hi: SIMD3(1, 0.5, 1), faceAxis: 4)]
        XCTAssertNotNil(ModelValidation.part(p))
    }
    func testAngledCutsClipTenonsInTheCNCOutline() {
        var p = board()
        p.cuts = [Cut(kind: "Tenon", lo: SIMD3(-2, 0, 1), hi: SIMD3(0, 0.75, 3))]
        p.trims = [Trim(axis: 0, positive: false, run: 1, angle: 45, farEdge: false)]
        let flat = Flatten.flat(p)
        // This end cut removes the entire negative-X tenon and a triangle from the blank.
        XCTAssertTrue(flat.tenons.isEmpty)
        XCTAssertEqual(area(flat.cutOutlines), 32, accuracy: 1e-5)
    }
    func testThicknessTenonsRequestEnoughStock() {
        var p = board()
        p.cuts = [Cut(kind: "Tenon", lo: SIMD3(2, 0.75, 1), hi: SIMD3(4, 1.25, 3))]
        let flat = Flatten.flat(p)
        XCTAssertEqual(flat.requiredThickness, 1.25)
        XCTAssertTrue(flat.notes.contains { $0.contains("thick blank") })
        XCTAssertEqual(CutList.rows([p])[0].t, 1.25)
    }
    func testCNCExportOpensLayoutReviewBeforeSaving() {
        let doc = document(); doc.add(board())
        doc.exportFlat(svg: false)
        XCTAssertTrue(doc.showCutList)
        XCTAssertEqual(doc.fabricationTab, 1)
    }
    func testBottomAndEdgeMachiningRemainDistinctInOutput() {
        var p = board()
        p.cuts = [Cut(kind: "Groove", lo: SIMD3(1, 0, 1), hi: SIMD3(9, 0.25, 2)),
                  Cut(kind: "Mortise", lo: SIMD3(0, 0.2, 1), hi: SIMD3(1, 0.5, 2))]
        let flat = Flatten.flat(p)
        XCTAssertTrue(flat.features.contains { $0.side == .bottom })
        XCTAssertTrue(flat.features.contains { $0.side == .edge })
        let result = Nesting.nest([flat], sheetL: 96, sheetW: 48, gap: 0.5)
        let dxf = CNCOut.dxf(CNCOut.prims(result, metric: true), metric: true)
        XCTAssertTrue(dxf.contains("POCKET_BOTTOM_6.35mm")); XCTAssertTrue(dxf.contains("SIDE_7.62mm"))
        XCTAssertTrue(flat.notes.contains { $0.contains("bottom") })
    }
}
