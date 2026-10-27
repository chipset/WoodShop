import XCTest
import simd
@testable import WoodShop

final class MeshInterchangeTests: XCTestCase {
    private func volume(_ part: Part) -> Double {
        var v = 0.0
        for poly in Geo.polys(for: part) {
            for i in 1..<(poly.pts.count - 1) { v += simd_dot(poly.pts[0], simd_cross(poly.pts[i], poly.pts[i + 1])) / 6.0 }
        }
        return v
    }
    private func model() -> [Part] {
        var a = Part(name: "Top", origin: SIMD3(1, 2, 3), size: SIMD3(12, 0.75, 4), species: .walnut)
        a.thicknessAxis = 1; a.grainDirection = 0
        a.cuts = [JoineryGen.pocketHole(part: a, face: FaceRef(part: a.id, axis: 1, positive: false), run: 0, towardPositiveEnd: true, entry: SIMD2(10, 2))]
        a.edges = [EdgeProfile(kind: .roundover, axis1: 1, pos1: true, axis2: 2, pos2: true, size: 0.25)]
        var b = Part(name: "Leg", origin: SIMD3(2, 0, 4), size: SIMD3(1.5, 2, 1.5), species: .oak)
        b.thicknessAxis = 0; b.grainDirection = 1
        return [a, b]
    }
    private func roundTrip(_ format: MeshFormat, millimeters: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws -> [Part] {
        let parts = model()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try MeshIO.write(format, parts: parts, millimeters: millimeters, url: url)
        let contents = try MeshIO.read(url)
        let scale = contents.inchesPerUnit ?? (millimeters ? 1 / 25.4 : 1)
        let result = MeshIO.parts(from: contents, scale: scale, zUp: contents.zUp ?? true, baseName: "rt")
        XCTAssertEqual(result.parts.count, 2, "\(format) parts, notes: \(result.notes)", file: file, line: line)
        return result.parts.sorted { volume($0) > volume($1) }
    }

    func testEveryFormatRoundTripsGeometryAndPosition() throws {
        let originals = model().sorted { volume($0) > volume($1) }
        for (format, mm) in [(MeshFormat.stl, false), (.stl, true), (.obj, false), (.ply, false), (.threeds, false), (.dxf, false), (.dxf, true), (.dae, false)] {
            let back = try roundTrip(format, millimeters: mm)
            guard back.count == 2 else { continue }
            for (o, b) in zip(originals, back) {
                // 3DS stores 32-bit floats and the DAE/DXF writers round to 5 decimals.
                XCTAssertEqual(volume(b), volume(o), accuracy: volume(o) * 2e-4, "\(format) \(mm) volume of \(o.name)")
                XCTAssertEqual(b.size.x, o.size.x, accuracy: 1e-3, "\(format) size")
                XCTAssertEqual(b.size.y, o.size.y, accuracy: 1e-3)
                XCTAssertEqual(b.size.z, o.size.z, accuracy: 1e-3)
                XCTAssertEqual(b.origin.x, o.origin.x, accuracy: 1e-3, "\(format) position")
                XCTAssertEqual(b.origin.y, o.origin.y, accuracy: 1e-3)
                XCTAssertEqual(b.origin.z, o.origin.z, accuracy: 1e-3)
            }
        }
    }

    func testUSDZExportsAndReadsBack() throws {
        let parts = model()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).usdz")
        defer { try? FileManager.default.removeItem(at: url) }
        try MeshIO.write(.usdz, parts: parts, millimeters: false, url: url)
        let contents = try MeshIO.read(url)
        XCTAssertEqual(contents.groups.count, 2)
    }

    func testKMZWrappingADaeImports() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kmz-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("models"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try MeshIO.write(.dae, parts: model(), millimeters: false, url: dir.appendingPathComponent("models/model.dae"))
        try "<kml/>".write(to: dir.appendingPathComponent("doc.kml"), atomically: true, encoding: .utf8)
        let kmz = dir.appendingPathComponent("test.kmz")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-r", "test.kmz", "doc.kml", "models"]
        try zip.run(); zip.waitUntilExit()
        let contents = try MeshIO.read(kmz)
        let result = MeshIO.parts(from: contents, scale: contents.inchesPerUnit ?? 1, zUp: contents.zUp ?? true, baseName: "k")
        XCTAssertEqual(result.parts.count, 2)
    }

    func testStlAsciiAndBinaryBothRead() throws {
        let ascii = """
        solid t
        facet normal 0 0 0
        outer loop
        vertex 0 0 0
        vertex 1 0 0
        vertex 0 1 0
        endloop
        endfacet
        endsolid
        """
        XCTAssertEqual(try MeshIO.readSTL(Data(ascii.utf8), name: "a").faces.count, 1)
        XCTAssertThrowsError(try MeshIO.readSTL(Data("nonsense".utf8), name: "x"))
    }

    func testOpenSurfacesAndTinyShapesAreSkippedWithANote() {
        let square: [[SIMD3<Double>]] = [[SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(5, 5, 0), SIMD3(0, 5, 0)]]
        let result = MeshIO.parts(from: MeshFileContents(groups: [MeshGroup(name: "Sheet", faces: square)]), scale: 1, zUp: false, baseName: "x")
        XCTAssertTrue(result.parts.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.contains("open") })
    }

    func testInsideOutAndInconsistentWindingAreRepaired() throws {
        // A 2x2x2 cube, one face wound the wrong way, the rest reversed.
        var c: [SIMD3<Double>] = []
        for i in 0..<8 { c.append(SIMD3<Double>(Double(i & 1) * 2, Double((i >> 1) & 1) * 2, Double((i >> 2) & 1) * 2)) }
        let quads: [[Int]] = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
        var faces = quads.map { q in q.map { c[$0] } }
        faces[0].reverse()
        let result = MeshIO.parts(from: MeshFileContents(groups: [MeshGroup(name: "Cube", faces: faces)]), scale: 1, zUp: false, baseName: "x")
        XCTAssertEqual(result.parts.count, 1)
        XCTAssertEqual(volume(result.parts[0]), 8, accuracy: 1e-9)
    }

    func testTwoSeparateShellsInOneGroupBecomeTwoParts() {
        func cube(_ o: Double) -> [[SIMD3<Double>]] {
            var c: [SIMD3<Double>] = []
            for i in 0..<8 { c.append(SIMD3<Double>(Double(i & 1) + o, Double((i >> 1) & 1), Double((i >> 2) & 1))) }
            let quads: [[Int]] = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
            return quads.map { q in q.map { c[$0] } }
        }
        // 1 inch cubes: below the 1/32 minimum? No, 1 in is fine.
        let result = MeshIO.parts(from: MeshFileContents(groups: [MeshGroup(name: "Pair", faces: cube(0) + cube(5))]), scale: 1, zUp: false, baseName: "x")
        XCTAssertEqual(result.parts.count, 2)
    }

    func testThreeDSRefusesObjectsTooBigForTheFormat() {
        var big = Part(name: "Big", origin: .zero, size: SIMD3(4, 4, 4), species: .oak)
        big.mesh = MeshSolid(faces: (0..<30000).map { i in
            let t = Double(i) / 30000
            return [SIMD3(t, 0, 0), SIMD3(t, 1, 0), SIMD3(t, 0, 1)]
        })
        XCTAssertThrowsError(try MeshIO.threeDS(MeshIO.groups([big], scale: 1)))
    }

    func testDXFWithOnly2DOutlinesIsNotTreatedAs3D() {
        XCTAssertThrowsError(try MeshIO.readDXFFaces("0\nSECTION\n2\nENTITIES\n0\nLINE\n0\nENDSEC\n0\nEOF\n", name: "x"))
    }

    func testSketchUpStyleColladaWithInstancedComponentsAndTransforms() throws {
        // A 2 x 2 x 2 inch cube defined once (polylist quads) and instanced twice, the second one moved and scaled by nodes.
        let dae = """
        <?xml version="1.0" encoding="utf-8"?>
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><unit name="inch" meter="0.0254"/><up_axis>Z_UP</up_axis></asset>
        <library_geometries><geometry id="cube" name="Cube"><mesh>
        <source id="p"><float_array id="pa" count="24">0 0 0 2 0 0 0 2 0 2 2 0 0 0 2 2 0 2 0 2 2 2 2 2</float_array>
        <technique_common><accessor source="#pa" count="8" stride="3"/></technique_common></source>
        <vertices id="v"><input semantic="POSITION" source="#p"/></vertices>
        <polylist count="6"><input semantic="VERTEX" source="#v" offset="0"/><vcount>4 4 4 4 4 4</vcount>
        <p>0 2 3 1 4 5 7 6 0 1 5 4 2 6 7 3 0 4 6 2 1 3 7 5</p></polylist>
        </mesh></geometry></library_geometries>
        <library_nodes><node id="comp" name="Block"><instance_geometry url="#cube"/></node></library_nodes>
        <library_visual_scenes><visual_scene id="S">
        <node id="a" name="First"><instance_node url="#comp"/></node>
        <node id="outer"><translate>10 0 0</translate><node id="b" name="Second"><matrix>1 0 0 0 0 1 0 5 0 0 1 0 0 0 0 1</matrix><instance_node url="#comp"/></node></node>
        </visual_scene></library_visual_scenes>
        <scene><instance_visual_scene url="#S"/></scene></COLLADA>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("su-\(UUID().uuidString).dae")
        defer { try? FileManager.default.removeItem(at: url) }
        try dae.write(to: url, atomically: true, encoding: .utf8)
        let contents = try MeshIO.read(url)
        XCTAssertEqual(contents.groups.count, 2)
        XCTAssertEqual(contents.inchesPerUnit ?? 0, 1, accuracy: 1e-9)
        let result = MeshIO.parts(from: contents, scale: contents.inchesPerUnit ?? 1, zUp: contents.zUp ?? false, baseName: "su")
        XCTAssertEqual(result.parts.count, 2, "\(result.notes)")
        for p in result.parts { XCTAssertEqual(volume(p), 8, accuracy: 1e-9) }
        // File Z-up becomes model Y-up: the second cube sits 10 right and 5 (file Y) back, i.e. model z = -5 - 2.
        let second = try XCTUnwrap(result.parts.first { $0.origin.x > 5 })
        XCTAssertEqual(second.origin.x, 10, accuracy: 1e-9)
        XCTAssertEqual(second.origin.z, -7, accuracy: 1e-9)
    }
}
