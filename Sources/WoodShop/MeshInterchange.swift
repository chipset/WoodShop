import Foundation
import SceneKit
import ModelIO
import AppKit
import UniformTypeIdentifiers
import simd

/// A named set of polygons straight from a file, in the file's own units and axes.
struct MeshGroup {
    var name: String
    var faces: [[SIMD3<Double>]]
    var color: SIMD3<Double>? = nil
}

struct MeshFileContents {
    var groups: [MeshGroup]
    /// Inches per file unit when the file states its units; nil when the user must say.
    var inchesPerUnit: Double? = nil
    /// Whether the file's own up axis is Z. nil = ask the user.
    var zUp: Bool? = nil
    var notes: [String] = []
}

enum MeshFormat: String, CaseIterable, Identifiable {
    case stl, obj, ply, dae, threeds = "3ds", dxf, usdz
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stl: return "STL"
        case .obj: return "OBJ"
        case .ply: return "PLY"
        case .dae: return "Collada DAE (SketchUp, Blender)"
        case .threeds: return "3D Studio 3DS"
        case .dxf: return "DXF 3D faces (CAD)"
        case .usdz: return "USDZ (Apple AR)"
        }
    }
    var fileExtension: String { rawValue }
    /// Formats that store their own length unit; the others get an explicit mm/inch choice.
    var carriesUnits: Bool { self == .dae || self == .usdz }
}

enum MeshIO {
    static let importExtensions = ["stl", "obj", "ply", "3ds", "dxf", "dae", "kmz", "usd", "usda", "usdc", "usdz"]
    static let faceLimit = 25000

    // MARK: Reading

    static func read(_ url: URL) throws -> MeshFileContents {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        let base = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "stl": return MeshFileContents(groups: [try readSTL(data, name: base)])
        case "obj": return MeshFileContents(groups: try readOBJ(String(decoding: data, as: UTF8.self), name: base))
        case "ply": return MeshFileContents(groups: [try readPLY(data, name: base)])
        case "3ds": return MeshFileContents(groups: try read3DS(data, name: base))
        case "dxf": return MeshFileContents(groups: try readDXFFaces(String(decoding: data, as: UTF8.self), name: base))
        case "dae": return try readDAE(url)
        case "kmz": return try readKMZ(url)
        case "usd", "usda", "usdc", "usdz": return try readUSD(url)
        default: throw ModelValidation.Failure(message: "Unsupported file type .\(ext).")
        }
    }

    static func readSTL(_ data: Data, name: String) throws -> MeshGroup {
        var faces: [[SIMD3<Double>]] = []
        func f32(_ o: Int) -> Double { Double(Float(bitPattern: data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })) }
        if data.count >= 84 {
            let n = Int(data.subdata(in: 80..<84).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            if 84 + n * 50 == data.count {
                for i in 0..<n {
                    let o = 84 + i * 50 + 12
                    faces.append((0..<3).map { SIMD3(f32(o + $0 * 12), f32(o + $0 * 12 + 4), f32(o + $0 * 12 + 8)) })
                }
                return MeshGroup(name: name, faces: faces)
            }
        }
        var pts: [SIMD3<Double>] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let w = line.split(whereSeparator: \.isWhitespace)
            if w.first?.lowercased() == "vertex", w.count >= 4, let x = Double(w[1]), let y = Double(w[2]), let z = Double(w[3]) {
                pts.append(SIMD3(x, y, z))
                if pts.count == 3 { faces.append(pts); pts = [] }
            }
        }
        guard !faces.isEmpty else { throw ModelValidation.Failure(message: "The STL file contains no triangles.") }
        return MeshGroup(name: name, faces: faces)
    }

    static func readOBJ(_ text: String, name: String) throws -> [MeshGroup] {
        var vertices: [SIMD3<Double>] = []
        var groups: [MeshGroup] = []
        var current = MeshGroup(name: name, faces: [])
        func flush() { if !current.faces.isEmpty { groups.append(current) } }
        for raw in text.split(whereSeparator: \.isNewline) {
            let fields = raw.split(whereSeparator: \.isWhitespace)
            guard let command = fields.first else { continue }
            switch command {
            case "v":
                let values = fields.dropFirst().prefix(3).compactMap { Double($0) }
                guard values.count == 3 else { throw ModelValidation.Failure(message: "Invalid OBJ vertex.") }
                vertices.append(SIMD3(values[0], values[1], values[2]))
            case "o", "g":
                flush()
                let label = fields.dropFirst().joined(separator: " ")
                current = MeshGroup(name: label.isEmpty ? name : label, faces: [])
            case "f":
                var ids: [Int] = []
                for token in fields.dropFirst() {
                    let head = token.split(separator: "/", omittingEmptySubsequences: false)[0]
                    if let n = Int(head) { ids.append(n < 0 ? vertices.count + n : n - 1) }
                }
                guard ids.count == fields.count - 1, ids.count >= 3, ids.allSatisfy(vertices.indices.contains) else {
                    throw ModelValidation.Failure(message: "Invalid OBJ face index.")
                }
                current.faces.append(ids.map { vertices[$0] })
            default: break
            }
        }
        flush()
        guard !groups.isEmpty else { throw ModelValidation.Failure(message: "The OBJ file contains no faces.") }
        return groups
    }

    static func readPLY(_ data: Data, name: String) throws -> MeshGroup {
        guard let headerEnd = data.range(of: Data("end_header".utf8)) else { throw ModelValidation.Failure(message: "Not a PLY file.") }
        var bodyStart = headerEnd.upperBound
        while bodyStart < data.count, data[bodyStart] != 0x0A { bodyStart += 1 }
        bodyStart += 1
        let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard let format = header.first(where: { $0.first == "format" })?[safe: 1] else { throw ModelValidation.Failure(message: "PLY format missing.") }
        guard format == "ascii" || format == "binary_little_endian" else { throw ModelValidation.Failure(message: "Only ASCII and little-endian binary PLY files are supported.") }
        var vertexCount = 0, faceCount = 0
        var vertexProps: [(name: String, type: String)] = []
        var faceCountType = "uchar", faceIndexType = "int"
        var element = ""
        for line in header {
            if line.first == "element", line.count >= 3 { element = line[1]; if element == "vertex" { vertexCount = Int(line[2]) ?? 0 } else if element == "face" { faceCount = Int(line[2]) ?? 0 } }
            else if line.first == "property" {
                if element == "vertex", line.count >= 3 { vertexProps.append((line[2], line[1])) }
                else if element == "face", line.count >= 5, line[1] == "list" { faceCountType = line[2]; faceIndexType = line[3] }
            }
        }
        guard vertexCount > 0, faceCount > 0, vertexCount < 5_000_000 else { throw ModelValidation.Failure(message: "The PLY file has no faces.") }
        func size(_ t: String) -> Int {
            switch t { case "char", "uchar", "int8", "uint8": return 1; case "short", "ushort", "int16", "uint16": return 2
            case "double", "float64": return 8; default: return 4 }
        }
        var vertices: [SIMD3<Double>] = [], faces: [[SIMD3<Double>]] = []
        if format == "ascii" {
            let lines = String(decoding: data[bodyStart...], as: UTF8.self).split(whereSeparator: \.isNewline)
            guard lines.count >= vertexCount + faceCount else { throw ModelValidation.Failure(message: "The PLY file is truncated.") }
            let xi = vertexProps.firstIndex { $0.name == "x" } ?? 0, yi = vertexProps.firstIndex { $0.name == "y" } ?? 1, zi = vertexProps.firstIndex { $0.name == "z" } ?? 2
            for i in 0..<vertexCount {
                let w = lines[i].split(whereSeparator: \.isWhitespace).map { Double($0) ?? .nan }
                guard w.count > max(xi, yi, zi) else { throw ModelValidation.Failure(message: "Invalid PLY vertex.") }
                vertices.append(SIMD3(w[xi], w[yi], w[zi]))
            }
            for i in 0..<faceCount {
                let w = lines[vertexCount + i].split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
                guard let n = w.first, n >= 3, w.count >= n + 1, w[1...n].allSatisfy(vertices.indices.contains) else { throw ModelValidation.Failure(message: "Invalid PLY face.") }
                faces.append(w[1...n].map { vertices[$0] })
            }
        } else {
            func read(_ type: String, _ o: inout Int) throws -> Double {
                let n = size(type)
                guard o + n <= data.count else { throw ModelValidation.Failure(message: "The PLY file is truncated.") }
                let slice = data.subdata(in: o..<o + n); o += n
                return slice.withUnsafeBytes { raw -> Double in
                    switch type {
                    case "char", "int8": return Double(raw.loadUnaligned(as: Int8.self))
                    case "uchar", "uint8": return Double(raw.loadUnaligned(as: UInt8.self))
                    case "short", "int16": return Double(raw.loadUnaligned(as: Int16.self))
                    case "ushort", "uint16": return Double(raw.loadUnaligned(as: UInt16.self))
                    case "int", "int32": return Double(raw.loadUnaligned(as: Int32.self))
                    case "uint", "uint32": return Double(raw.loadUnaligned(as: UInt32.self))
                    case "double", "float64": return raw.loadUnaligned(as: Double.self)
                    default: return Double(raw.loadUnaligned(as: Float.self))
                    }
                }
            }
            var o = bodyStart
            for _ in 0..<vertexCount {
                var v = SIMD3<Double>.zero
                for p in vertexProps {
                    let value = try read(p.type, &o)
                    if p.name == "x" { v.x = value } else if p.name == "y" { v.y = value } else if p.name == "z" { v.z = value }
                }
                vertices.append(v)
            }
            for _ in 0..<faceCount {
                let n = Int(try read(faceCountType, &o))
                guard n >= 3, n < 10000 else { throw ModelValidation.Failure(message: "Invalid PLY face.") }
                var ids: [Int] = []
                for _ in 0..<n { ids.append(Int(try read(faceIndexType, &o))) }
                guard ids.allSatisfy(vertices.indices.contains) else { throw ModelValidation.Failure(message: "Invalid PLY face index.") }
                faces.append(ids.map { vertices[$0] })
            }
        }
        return MeshGroup(name: name, faces: faces)
    }

    /// 3D Studio: only geometry (vertex and face lists of each object) is used.
    static func read3DS(_ data: Data, name: String) throws -> [MeshGroup] {
        func u16(_ o: Int) -> Int { Int(data.subdata(in: o..<o + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }) }
        func u32(_ o: Int) -> Int { Int(data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
        func f32(_ o: Int) -> Double { Double(Float(bitPattern: data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })) }
        guard data.count > 6, u16(0) == 0x4D4D else { throw ModelValidation.Failure(message: "Not a 3DS file.") }
        var groups: [MeshGroup] = []
        func walk(_ start: Int, _ end: Int, objectName: String?) throws {
            var o = start
            var verts: [SIMD3<Double>] = [], tris: [[Int]] = []
            while o + 6 <= end {
                let id = u16(o), length = u32(o + 2)
                guard length >= 6, o + length <= end else { throw ModelValidation.Failure(message: "The 3DS file is damaged.") }
                let body = o + 6, next = o + length
                switch id {
                case 0x3D3D: try walk(body, next, objectName: nil)
                case 0x4000:
                    var q = body
                    while q < next, data[q] != 0 { q += 1 }
                    let label = String(decoding: data[body..<q], as: UTF8.self)
                    try walk(q + 1, next, objectName: label)
                case 0x4100: try walk(body, next, objectName: objectName)
                case 0x4110:
                    let n = u16(body)
                    guard body + 2 + n * 12 <= next else { throw ModelValidation.Failure(message: "The 3DS file is damaged.") }
                    verts = (0..<n).map { SIMD3(f32(body + 2 + $0 * 12), f32(body + 6 + $0 * 12), f32(body + 10 + $0 * 12)) }
                case 0x4120:
                    let n = u16(body)
                    guard body + 2 + n * 8 <= next else { throw ModelValidation.Failure(message: "The 3DS file is damaged.") }
                    tris = (0..<n).map { [u16(body + 2 + $0 * 8), u16(body + 4 + $0 * 8), u16(body + 6 + $0 * 8)] }
                default: break
                }
                o = next
            }
            if !tris.isEmpty, !verts.isEmpty {
                guard tris.allSatisfy({ $0.allSatisfy(verts.indices.contains) }) else { throw ModelValidation.Failure(message: "The 3DS file has invalid face indices.") }
                groups.append(MeshGroup(name: objectName ?? name, faces: tris.map { $0.map { verts[$0] } }))
            }
        }
        try walk(6, min(u32(2), data.count), objectName: nil)
        guard !groups.isEmpty else { throw ModelValidation.Failure(message: "The 3DS file contains no meshes.") }
        return groups
    }

    /// 3DFACE entities (and polyface meshes), grouped by layer.
    static func readDXFFaces(_ text: String, name: String) throws -> [MeshGroup] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var pairs: [(Int, String)] = []
        var i = 0
        while i + 1 < lines.count { if let code = Int(lines[i]) { pairs.append((code, lines[i + 1])) }; i += 2 }
        var byLayer: [String: [[SIMD3<Double>]]] = [:], order: [String] = []
        func add(_ layer: String, _ face: [SIMD3<Double>]) { if byLayer[layer] == nil { order.append(layer) }; byLayer[layer, default: []].append(face) }
        var k = 0
        // Polyface state
        var polyLayer = "", polyVerts: [SIMD3<Double>] = [], polyIdx: [[Int]] = [], inPolyface = false
        while k < pairs.count {
            guard pairs[k].0 == 0 else { k += 1; continue }
            let type = pairs[k].1
            var j = k + 1
            var entity: [(Int, String)] = []
            while j < pairs.count, pairs[j].0 != 0 { entity.append(pairs[j]); j += 1 }
            func num(_ code: Int) -> Double { entity.first { $0.0 == code }.flatMap { Double($0.1) } ?? 0 }
            let layer = entity.first { $0.0 == 8 }?.1 ?? name
            switch type {
            case "3DFACE":
                var pts = (0..<4).map { SIMD3(num(10 + $0), num(20 + $0), num(30 + $0)) }
                if pts[3] == pts[2] { pts.removeLast() }
                add(layer, pts)
            case "POLYLINE":
                inPolyface = (Int(num(70)) & 64) != 0
                polyLayer = layer; polyVerts = []; polyIdx = []
            case "VERTEX" where inPolyface:
                let flags = Int(num(70))
                if flags & 128 != 0, flags & 64 == 0 {
                    polyIdx.append([Int(num(71)), Int(num(72)), Int(num(73)), Int(num(74))].filter { $0 != 0 })
                } else { polyVerts.append(SIMD3(num(10), num(20), num(30))) }
            case "SEQEND" where inPolyface:
                for face in polyIdx where face.count >= 3 {
                    let ids = face.map { abs($0) - 1 }
                    if ids.allSatisfy(polyVerts.indices.contains) { add(polyLayer, ids.map { polyVerts[$0] }) }
                }
                inPolyface = false
            default: break
            }
            k = j
        }
        guard !order.isEmpty else { throw ModelValidation.Failure(message: "No 3D faces found. This DXF holds 2D geometry; use it as a flat outline instead.") }
        return order.map { MeshGroup(name: $0, faces: byLayer[$0]!) }
    }

    static func readKMZ(_ url: URL) throws -> MeshFileContents {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kmz-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", url.path, "-d", dir.path]
        unzip.standardOutput = FileHandle.nullDevice; unzip.standardError = FileHandle.nullDevice
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw ModelValidation.Failure(message: "The KMZ archive could not be opened.") }
        let found = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "dae" && !$0.path.contains("__MACOSX") }.sorted { $0.path < $1.path } ?? []
        guard let dae = found.first else { throw ModelValidation.Failure(message: "This KMZ holds map data but no 3D model.") }
        var result = try readDAE(dae)
        for i in result.groups.indices where result.groups[i].name.isEmpty { result.groups[i].name = url.deletingPathExtension().lastPathComponent }
        if found.count > 1 { result.notes.append("The KMZ has \(found.count) models; imported the first.") }
        return result
    }

    /// Collada: geometry, node transforms and instancing (what SketchUp, Blender and Google Earth write).
    static func readDAE(_ url: URL) throws -> MeshFileContents {
        let doc = try XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement() else { throw ModelValidation.Failure(message: "The Collada file is empty.") }
        func kids(_ e: XMLElement, _ name: String) -> [XMLElement] { (e.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name || $0.name == name } }
        func first(_ e: XMLElement, _ name: String) -> XMLElement? { kids(e, name).first }
        func numbers(_ e: XMLElement?) -> [Double] { (e?.stringValue ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) } }
        func ints(_ e: XMLElement?) -> [Int] { (e?.stringValue ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int($0) } }
        func ref(_ s: String?) -> String { String((s ?? "").drop { $0 == "#" }) }

        var meters = 1.0, zUp = false
        if let asset = first(root, "asset") {
            if let m = first(asset, "unit")?.attribute(forName: "meter")?.stringValue, let v = Double(m), v > 0 { meters = v }
            zUp = first(asset, "up_axis")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "Z_UP"
            if first(asset, "up_axis")?.stringValue?.contains("X_UP") == true { throw ModelValidation.Failure(message: "X-up Collada files are not supported.") }
        }
        // Geometries
        var geometries: [String: MeshGroup] = [:]
        for lib in kids(root, "library_geometries") {
            for geo in kids(lib, "geometry") {
                guard let mesh = first(geo, "mesh"), let id = geo.attribute(forName: "id")?.stringValue else { continue }
                var sources: [String: (data: [Double], stride: Int)] = [:]
                for src in kids(mesh, "source") {
                    guard let sid = src.attribute(forName: "id")?.stringValue else { continue }
                    let stride = Int(first(first(src, "technique_common") ?? src, "accessor")?.attribute(forName: "stride")?.stringValue ?? "") ?? 3
                    sources[sid] = (numbers(first(src, "float_array")), max(stride, 1))
                }
                var vertexSource: [String: String] = [:]
                for v in kids(mesh, "vertices") {
                    if let vid = v.attribute(forName: "id")?.stringValue,
                       let input = kids(v, "input").first(where: { $0.attribute(forName: "semantic")?.stringValue == "POSITION" }) {
                        vertexSource[vid] = ref(input.attribute(forName: "source")?.stringValue)
                    }
                }
                var faces: [[SIMD3<Double>]] = []
                for prim in (mesh.children ?? []).compactMap({ $0 as? XMLElement }) where ["triangles", "polylist", "polygons", "tristrips", "trifans"].contains(prim.localName ?? prim.name ?? "") {
                    let kind = prim.localName ?? prim.name ?? ""
                    let inputs = kids(prim, "input")
                    guard let vin = inputs.first(where: { $0.attribute(forName: "semantic")?.stringValue == "VERTEX" }) else { continue }
                    let offset = Int(vin.attribute(forName: "offset")?.stringValue ?? "0") ?? 0
                    let stride = (inputs.compactMap { Int($0.attribute(forName: "offset")?.stringValue ?? "0") }.max() ?? 0) + 1
                    guard let srcID = vertexSource[ref(vin.attribute(forName: "source")?.stringValue)], let src = sources[srcID], src.stride >= 3 else { continue }
                    func point(_ i: Int) -> SIMD3<Double>? {
                        let o = i * src.stride
                        return o + 2 < src.data.count ? SIMD3(src.data[o], src.data[o + 1], src.data[o + 2]) : nil
                    }
                    func vertexIDs(_ p: [Int]) -> [Int] { Swift.stride(from: offset, to: p.count, by: stride).map { p[$0] } }
                    switch kind {
                    case "triangles":
                        let v = vertexIDs(ints(first(prim, "p")))
                        for t in Swift.stride(from: 0, to: v.count - 2, by: 3) { if let a = point(v[t]), let b = point(v[t + 1]), let c = point(v[t + 2]) { faces.append([a, b, c]) } }
                    case "polylist":
                        let counts = ints(first(prim, "vcount")), v = vertexIDs(ints(first(prim, "p")))
                        var o = 0
                        for n in counts where n >= 3 && o + n <= v.count {
                            let pts = v[o..<o + n].compactMap(point)
                            if pts.count == n { faces.append(pts) }
                            o += n
                        }
                    case "polygons":
                        for p in kids(prim, "p") {
                            let pts = vertexIDs(ints(p)).compactMap(point)
                            if pts.count >= 3 { faces.append(pts) }
                        }
                    default:
                        for p in kids(prim, "p") {
                            let v = vertexIDs(ints(p)).compactMap(point)
                            guard v.count >= 3 else { continue }
                            for t in 0..<(v.count - 2) {
                                if kind == "tristrips" { faces.append(t % 2 == 0 ? [v[t], v[t + 1], v[t + 2]] : [v[t + 1], v[t], v[t + 2]]) }
                                else { faces.append([v[0], v[t + 1], v[t + 2]]) }
                            }
                        }
                    }
                }
                if !faces.isEmpty { geometries[id] = MeshGroup(name: geo.attribute(forName: "name")?.stringValue ?? id, faces: faces) }
            }
        }
        guard !geometries.isEmpty else { throw ModelValidation.Failure(message: "The Collada file contains no meshes.") }
        // Nodes
        var nodeByID: [String: XMLElement] = [:]
        func index(_ e: XMLElement) { for n in kids(e, "node") { if let id = n.attribute(forName: "id")?.stringValue { nodeByID[id] = n }; index(n) } }
        for lib in kids(root, "library_nodes") { index(lib) }
        for lib in kids(root, "library_visual_scenes") { for vs in kids(lib, "visual_scene") { index(vs) } }
        func transform(_ n: XMLElement) -> simd_double4x4 {
            var m = matrix_identity_double4x4
            for c in (n.children ?? []).compactMap({ $0 as? XMLElement }) {
                let v = numbers(c)
                switch c.localName ?? c.name ?? "" {
                case "matrix" where v.count == 16:
                    let t = simd_double4x4(rows: [SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]), SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])])
                    m = m * t
                case "translate" where v.count == 3:
                    var t = matrix_identity_double4x4; t.columns.3 = SIMD4(v[0], v[1], v[2], 1); m = m * t
                case "scale" where v.count == 3:
                    m = m * simd_double4x4(diagonal: SIMD4(v[0], v[1], v[2], 1))
                case "rotate" where v.count == 4:
                    let axis = simdNormalize(SIMD3(v[0], v[1], v[2])), a = v[3] * .pi / 180
                    let q = simd_quatd(angle: a, axis: axis)
                    var r = simd_double4x4(q); r.columns.3 = SIMD4(0, 0, 0, 1)
                    m = m * r
                default: break
                }
            }
            return m
        }
        var groups: [MeshGroup] = []
        var depth = 0
        func visit(_ n: XMLElement, _ parent: simd_double4x4) {
            guard depth < 64 else { return }
            depth += 1; defer { depth -= 1 }
            let world = parent * transform(n)
            for inst in kids(n, "instance_geometry") {
                if var g = geometries[ref(inst.attribute(forName: "url")?.stringValue)] {
                    g.faces = g.faces.map { f in f.map { let w = world * SIMD4($0.x, $0.y, $0.z, 1); return SIMD3(w.x, w.y, w.z) } }
                    if let label = n.attribute(forName: "name")?.stringValue, !label.isEmpty, label != g.name { g.name = label }
                    groups.append(g)
                }
            }
            for inst in kids(n, "instance_node") { if let target = nodeByID[ref(inst.attribute(forName: "url")?.stringValue)] { visit(target, world) } }
            for child in kids(n, "node") { visit(child, world) }
        }
        var usedScene = false
        for scene in kids(root, "scene") {
            for ivs in kids(scene, "instance_visual_scene") {
                for lib in kids(root, "library_visual_scenes") {
                    for vs in kids(lib, "visual_scene") where vs.attribute(forName: "id")?.stringValue == ref(ivs.attribute(forName: "url")?.stringValue) {
                        for n in kids(vs, "node") { visit(n, matrix_identity_double4x4) }
                        usedScene = true
                    }
                }
            }
        }
        if !usedScene || groups.isEmpty { groups = Array(geometries.values) }
        return MeshFileContents(groups: groups, inchesPerUnit: meters / 0.0254, zUp: zUp)
    }

    static func readUSD(_ url: URL) throws -> MeshFileContents {
        let asset = MDLAsset(url: url)
        var groups: [MeshGroup] = []
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
            var points: [SIMD3<Double>] = []
            for i in 0..<mesh.vertexCount {
                let p = positions.dataStart.advanced(by: i * positions.stride).assumingMemoryBound(to: Float.self)
                let w = world * SIMD4<Float>(p[0], p[1], p[2], 1)
                points.append(SIMD3(Double(w.x), Double(w.y), Double(w.z)))
            }
            var faces: [[SIMD3<Double>]] = []
            for case let sub as MDLSubmesh in mesh.submeshes ?? [] {
                guard sub.geometryType == .triangles || sub.geometryType == .quads else { continue }
                let per = sub.geometryType == .triangles ? 3 : 4
                let buffer = sub.indexBuffer(asIndexType: .uInt32)
                let idx = buffer.map().bytes.assumingMemoryBound(to: UInt32.self)
                for f in 0..<sub.indexCount / per {
                    let ids = (0..<per).map { Int(idx[f * per + $0]) }
                    if ids.allSatisfy(points.indices.contains) { faces.append(ids.map { points[$0] }) }
                }
            }
            if !faces.isEmpty { groups.append(MeshGroup(name: mesh.name.isEmpty ? url.deletingPathExtension().lastPathComponent : mesh.name, faces: faces)) }
        }
        guard !groups.isEmpty else { throw ModelValidation.Failure(message: "No triangle or quad meshes were found in this USD file.") }
        let up = asset.upAxis
        return MeshFileContents(groups: groups, zUp: abs(up.z) > abs(up.y))
    }

    // MARK: Turning faces into parts

    /// Weld vertices, separate every closed shell into its own part, and orient faces outward.
    static func parts(from contents: MeshFileContents, scale: Double, zUp: Bool, baseName: String,
                      boardsFromBlocks: Bool = true, defaultSpecies: Species = .oak) -> (parts: [Part], notes: [String]) {
        var notes = contents.notes
        var blocks = 0
        var parts: [Part] = []
        var skippedOpen = 0, skippedSmall = 0, skippedBig = 0
        func convert(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let q = p * scale
            return zUp ? SIMD3(q.x, q.z, -q.y) : q
        }
        for group in contents.groups {
            var index: [SIMD3<Int64>: Int] = [:]
            var verts: [SIMD3<Double>] = []
            func id(_ p: SIMD3<Double>) -> Int {
                let key = SIMD3<Int64>(Int64((p.x * 1e4).rounded()), Int64((p.y * 1e4).rounded()), Int64((p.z * 1e4).rounded()))
                if let i = index[key] { return i }
                verts.append(p); index[key] = verts.count - 1; return verts.count - 1
            }
            var tris: [[Int]] = []
            for face in group.faces {
                let pts = face.map(convert)
                guard pts.allSatisfy(ModelValidation.finite) else { continue }
                var triangles: [[SIMD3<Double>]] = []
                if pts.count == 3 { triangles = [pts] }
                else {
                    let n = pts.indices.reduce(SIMD3<Double>.zero) { $0 + cross(pts[$1] - pts[0], pts[($1 + 1) % pts.count] - pts[0]) }
                    if norm(n) > 1e-12 {
                        let normal = simdNormalize(n)
                        let axis = (0..<3).max { abs(normal[$0]) < abs(normal[$1]) }!, u = (axis + 1) % 3, v = (axis + 2) % 3
                        let flat = pts.map { SIMD2($0[u], $0[v]) }
                        if Planar.isSimple(flat) {
                            for t in Planar.triangulate(flat) {
                                let tri = t.compactMap { corner in flat.firstIndex(of: corner).map { pts[$0] } }
                                if tri.count == 3 { triangles.append(tri) }
                            }
                        }
                    }
                    if triangles.isEmpty { for i in 1..<(pts.count - 1) { triangles.append([pts[0], pts[i], pts[i + 1]]) } }
                }
                for t in triangles {
                    let ids = t.map(id)
                    if Set(ids).count == 3 { tris.append(ids) }
                }
            }
            guard !tris.isEmpty else { continue }
            // Connected shells.
            var parent = Array(0..<verts.count)
            func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
            for t in tris { parent[find(t[0])] = find(t[1]); parent[find(t[1])] = find(t[2]) }
            var shells: [Int: [[Int]]] = [:], shellOrder: [Int] = []
            for t in tris { let r = find(t[0]); if shells[r] == nil { shellOrder.append(r) }; shells[r, default: []].append(t) }
            for (n, root) in shellOrder.enumerated() {
                var shell = shells[root]!
                // Closed means every edge is shared by exactly two triangles. Exporters often leave
                // T-junctions (a vertex on the middle of a neighbour's edge); split those edges first.
                repairTJunctions(&shell, verts)
                var edgeUse: [SIMD2<Int>: [Int]] = [:]
                for (ti, t) in shell.enumerated() { for e in 0..<3 { let a = t[e], b = t[(e + 1) % 3]; edgeUse[SIMD2(min(a, b), max(a, b)), default: []].append(ti) } }
                guard edgeUse.values.allSatisfy({ $0.count == 2 }) else { skippedOpen += 1; continue }
                // Make winding consistent, then outward.
                var flipped = Array(repeating: false, count: shell.count), seen = Array(repeating: false, count: shell.count)
                func directed(_ t: Int, _ a: Int, _ b: Int) -> Bool {
                    let v = flipped[t] ? Array(shell[t].reversed()) : shell[t]
                    return (0..<3).contains { v[$0] == a && v[($0 + 1) % 3] == b }
                }
                var queue = [0]; seen[0] = true
                var consistent = true
                while let t = queue.popLast() {
                    let v = flipped[t] ? Array(shell[t].reversed()) : shell[t]
                    for e in 0..<3 {
                        let a = v[e], b = v[(e + 1) % 3]
                        for u in edgeUse[SIMD2(min(a, b), max(a, b))]! where u != t {
                            if !seen[u] { seen[u] = true; flipped[u] = directed(u, a, b); queue.append(u) }
                            else if directed(u, a, b) { consistent = false }
                        }
                    }
                }
                guard consistent, !seen.contains(false) else { skippedOpen += 1; continue }
                for i in shell.indices where flipped[i] { shell[i].reverse() }
                let volume = shell.reduce(0.0) { $0 + simd_dot(verts[$1[0]], cross(verts[$1[1]], verts[$1[2]])) / 6 }
                if volume < 0 { for i in shell.indices { shell[i].reverse() } }
                guard shell.count <= faceLimit else { skippedBig += 1; continue }
                let polys = shell.compactMap { t -> Geo.Poly? in
                    let p = t.map { verts[$0] }
                    return SolidCSG.face(p, normal: cross(p[1] - p[0], p[2] - p[0]))
                }
                let label = group.name.isEmpty ? baseName : group.name
                let partName = shellOrder.count > 1 ? "\(label) \(n + 1)" : label
                if boardsFromBlocks, let board = block(polys, volume: abs(volume), name: partName, defaultSpecies: defaultSpecies) {
                    blocks += 1
                    parts.append(board)
                    continue
                }
                do {
                    var part = try MeshTools.part(polygons: polys, name: partName)
                    if let error = ModelValidation.part(part) { throw ModelValidation.Failure(message: error) }
                    part.name = part.name.trimmingCharacters(in: .whitespaces)
                    parts.append(part)
                } catch { skippedSmall += 1 }
            }
        }
        if blocks > 0 { notes.append("Made \(blocks) rectangular solid(s) into boards with grain along the length.") }
        if skippedOpen > 0 { notes.append("Skipped \(skippedOpen) open or non-manifold surface(s); only closed solids can become boards.") }
        if skippedSmall > 0 { notes.append("Skipped \(skippedSmall) shape(s) thinner than 1/32 in.") }
        if skippedBig > 0 { notes.append("Skipped \(skippedBig) shape(s) with more than \(faceLimit) triangles; simplify them first.") }
        return (parts, notes)
    }

    /// A solid that fills its bounding box is a plain board: give it a thickness, a grain direction and a species.
    static func block(_ polys: [Geo.Poly], volume: Double, name: String, defaultSpecies: Species) -> Part? {
        let points = polys.flatMap(\.pts)
        guard let first = points.first else { return nil }
        let lo = points.reduce(first, pointwiseMin), hi = points.reduce(first, pointwiseMax)
        let size = hi - lo
        guard (0..<3).allSatisfy({ size[$0] >= 1.0 / 32 }) else { return nil }
        let box = size.x * size.y * size.z
        guard box > 0, volume >= box * 0.9995 else { return nil }
        func r(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }
        let sz = SIMD3(r(size.x), r(size.y), r(size.z))
        var board = Part(name: name, origin: SIMD3(r(lo.x), r(lo.y), r(lo.z)), size: sz, species: species(named: name) ?? defaultSpecies)
        let t = (0..<3).min { sz[$0] < sz[$1] }!
        let rest = (0..<3).filter { $0 != t }
        board.thicknessAxis = t
        board.grainDirection = rest.max { sz[$0] < sz[$1] }!
        return ModelValidation.part(board) == nil ? board : nil
    }

    /// Species hinted by a part name such as "Walnut shelf" or "Maple leg".
    static func species(named name: String) -> Species? {
        let n = name.lowercased()
        let table: [(String, Species)] = [("walnut", .walnut), ("cherry", .cherry), ("maple", .maple), ("poplar", .poplar), ("oak", .oak),
                                          ("plywood", .plywood), ("mdf", .mdf), ("pine", .pine), ("fir", .pine), ("spruce", .pine)]
        return table.first { n.contains($0.0) }?.1
    }

    /// Split triangle edges that pass through other vertices, so meshes with T-junctions become watertight.
    static func repairTJunctions(_ tris: inout [[Int]], _ verts: [SIMD3<Double>]) {
        for _ in 0..<4 {
            var use: [SIMD2<Int>: Int] = [:]
            for t in tris { for e in 0..<3 { let a = t[e], b = t[(e + 1) % 3]; use[SIMD2(min(a, b), max(a, b)), default: 0] += 1 } }
            let open = use.filter { $0.value == 1 }.keys
            guard !open.isEmpty else { return }
            var candidates = Set<Int>()
            for e in open { candidates.insert(e.x); candidates.insert(e.y) }
            var splits: [SIMD2<Int>: [Int]] = [:]
            for e in open {
                let a = verts[e.x], b = verts[e.y], d = b - a, len2 = simd_length_squared(d)
                guard len2 > 1e-12 else { continue }
                for c in candidates where c != e.x && c != e.y {
                    let t = simd_dot(verts[c] - a, d) / len2
                    guard t > 1e-6, t < 1 - 1e-6, simd_length(verts[c] - (a + d * t)) < 2e-4 else { continue }
                    splits[e, default: []].append(c)
                }
            }
            guard !splits.isEmpty else { return }
            var out: [[Int]] = []
            for t in tris {
                var pending = [t]
                for k in 0..<3 {
                    let a = t[k], b = t[(k + 1) % 3]
                    guard let extra = splits[SIMD2(min(a, b), max(a, b))], pending.count == 1 else { continue }
                    let sorted = extra.sorted { simd_length_squared(verts[$0] - verts[a]) < simd_length_squared(verts[$1] - verts[a]) }
                    let apex = t[(k + 2) % 3]
                    let chain = [a] + sorted + [b]
                    pending = (0..<chain.count - 1).map { [chain[$0], chain[$0 + 1], apex] }
                }
                out += pending
            }
            tris = out
        }
    }

    // MARK: Writing

    /// World-space polygons, Z up, scaled, one group per part.
    static func groups(_ parts: [Part], scale: Double) -> [(part: Part, faces: [[SIMD3<Double>]])] {
        parts.map { part in
            let faces = Geo.polys(for: part).map { poly in
                poly.pts.map { p -> SIMD3<Double> in
                    let w = part.toWorld(p) * scale
                    return SIMD3(w.x, -w.z, w.y)
                }
            }
            return (part, faces)
        }
    }

    private static func triangles(_ faces: [[SIMD3<Double>]]) -> [[SIMD3<Double>]] {
        faces.flatMap { f in (1..<max(f.count - 1, 1)).map { [f[0], f[$0], f[$0 + 1]] } }
    }
    private static func safeName(_ s: String) -> String {
        let t = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? Character($0) : "_" }
        return String(t).isEmpty ? "part" : String(t)
    }

    static func write(_ format: MeshFormat, parts: [Part], millimeters: Bool, url: URL) throws {
        let scale = millimeters ? 25.4 : 1.0
        switch format {
        case .stl: try Exporter3D.stl(parts, scale: scale).write(to: url, options: .atomic)
        case .obj: try Exporter3D.obj(parts, scale: scale).write(to: url, atomically: true, encoding: .utf8)
        case .ply: try ply(groups(parts, scale: scale)).write(to: url, atomically: true, encoding: .utf8)
        case .threeds: try threeDS(groups(parts, scale: scale)).write(to: url, options: .atomic)
        case .dxf: try dxf(groups(parts, scale: scale), millimeters: millimeters).write(to: url, atomically: true, encoding: .utf8)
        case .dae: try dae(groups(parts, scale: 1), unitMeters: 0.0254).write(to: url, atomically: true, encoding: .utf8)
        case .usdz: try usdz(groups(parts, scale: 0.0254), url: url)
        }
    }

    static func ply(_ groups: [(part: Part, faces: [[SIMD3<Double>]])]) -> String {
        var verts: [String] = [], faces: [String] = []
        for g in groups {
            for f in g.faces {
                let base = verts.count
                verts += f.map { String(format: "%.5f %.5f %.5f", $0.x, $0.y, $0.z) }
                faces.append("\(f.count) " + (0..<f.count).map { String(base + $0) }.joined(separator: " "))
            }
        }
        return "ply\nformat ascii 1.0\ncomment WoodShop export (Z up)\nelement vertex \(verts.count)\nproperty float x\nproperty float y\nproperty float z\nelement face \(faces.count)\nproperty list uchar int vertex_indices\nend_header\n"
            + verts.joined(separator: "\n") + "\n" + faces.joined(separator: "\n") + "\n"
    }

    static func threeDS(_ groups: [(part: Part, faces: [[SIMD3<Double>]])]) throws -> Data {
        func chunk(_ id: UInt16, _ body: Data) -> Data {
            var d = Data()
            withUnsafeBytes(of: id.littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(body.count + 6).littleEndian) { d.append(contentsOf: $0) }
            return d + body
        }
        var objects = Data()
        for (index, g) in groups.enumerated() {
            var verts: [SIMD3<Double>] = [], map: [SIMD3<Int64>: Int] = [:], tris: [[Int]] = []
            for t in triangles(g.faces) {
                tris.append(t.map { p in
                    let key = SIMD3<Int64>(Int64((p.x * 1e5).rounded()), Int64((p.y * 1e5).rounded()), Int64((p.z * 1e5).rounded()))
                    if let i = map[key] { return i }
                    verts.append(p); map[key] = verts.count - 1; return verts.count - 1
                })
            }
            guard verts.count <= 65535, tris.count <= 65535 else {
                throw ModelValidation.Failure(message: "\(g.part.name) has too many vertices for the 3DS format (limit 65,535). Use DAE, OBJ or STL instead.")
            }
            var vb = Data(), fb = Data()
            withUnsafeBytes(of: UInt16(verts.count).littleEndian) { vb.append(contentsOf: $0) }
            for v in verts { for c in [v.x, v.y, v.z] { withUnsafeBytes(of: Float(c).bitPattern.littleEndian) { vb.append(contentsOf: $0) } } }
            withUnsafeBytes(of: UInt16(tris.count).littleEndian) { fb.append(contentsOf: $0) }
            for t in tris { for i in t { withUnsafeBytes(of: UInt16(i).littleEndian) { fb.append(contentsOf: $0) } }; fb.append(contentsOf: [7, 0]) }
            var name = Data(String(safeName(g.part.name).prefix(10)).appending("\(index)").utf8)
            name.append(0)
            objects += chunk(0x4000, name + chunk(0x4100, chunk(0x4110, vb) + chunk(0x4120, fb)))
        }
        var version = Data(); withUnsafeBytes(of: UInt32(3).littleEndian) { version.append(contentsOf: $0) }
        return chunk(0x4D4D, chunk(0x0002, version) + chunk(0x3D3D, objects))
    }

    static func dxf(_ groups: [(part: Part, faces: [[SIMD3<Double>]])], millimeters: Bool) -> String {
        var o = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$INSUNITS\n70\n\(millimeters ? 4 : 1)\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        for g in groups {
            let layer = safeName(g.part.name)
            for t in triangles(g.faces) {
                o += "0\n3DFACE\n8\n\(layer)\n"
                let pts = [t[0], t[1], t[2], t[2]]
                for (i, p) in pts.enumerated() {
                    o += "\(10 + i)\n" + String(format: "%.5f", p.x) + "\n\(20 + i)\n" + String(format: "%.5f", p.y) + "\n\(30 + i)\n" + String(format: "%.5f", p.z) + "\n"
                }
            }
        }
        return o + "0\nENDSEC\n0\nEOF\n"
    }

    static func dae(_ groups: [(part: Part, faces: [[SIMD3<Double>]])], unitMeters: Double) -> String {
        let iso = ISO8601DateFormatter().string(from: Date())
        var effects = "", materials = "", geometries = "", nodes = ""
        var seen: Set<Species> = []
        for (i, g) in groups.enumerated() {
            let sp = g.part.species
            let mat = "mat_" + safeName(sp.rawValue)
            if seen.insert(sp).inserted {
                let c = sp.base.usingColorSpace(.deviceRGB) ?? sp.base
                effects += "<effect id=\"fx_\(mat)\"><profile_COMMON><technique sid=\"common\"><lambert><diffuse><color>\(String(format: "%.3f %.3f %.3f", c.redComponent, c.greenComponent, c.blueComponent)) 1</color></diffuse></lambert></technique></profile_COMMON></effect>\n"
                materials += "<material id=\"\(mat)\" name=\"\(sp.rawValue)\"><instance_effect url=\"#fx_\(mat)\"/></material>\n"
            }
            var verts: [SIMD3<Double>] = [], map: [SIMD3<Int64>: Int] = [:], idx: [Int] = []
            let tris = triangles(g.faces)
            for t in tris { for p in t {
                let key = SIMD3<Int64>(Int64((p.x * 1e5).rounded()), Int64((p.y * 1e5).rounded()), Int64((p.z * 1e5).rounded()))
                if let k = map[key] { idx.append(k) } else { verts.append(p); map[key] = verts.count - 1; idx.append(verts.count - 1) }
            } }
            let id = "geo\(i)"
            let name: String = CNCOut.xmlEscaped(g.part.name)
            let positions: String = verts.map { String(format: "%.5f %.5f %.5f", $0.x, $0.y, $0.z) }.joined(separator: " ")
            let indices: String = idx.map(String.init).joined(separator: " ")
            var geo = "<geometry id=\"\(id)\" name=\"\(name)\"><mesh>"
            geo += "<source id=\"\(id)-pos\"><float_array id=\"\(id)-arr\" count=\"\(verts.count * 3)\">" + positions + "</float_array>"
            geo += "<technique_common><accessor source=\"#\(id)-arr\" count=\"\(verts.count)\" stride=\"3\">"
            geo += "<param name=\"X\" type=\"float\"/><param name=\"Y\" type=\"float\"/><param name=\"Z\" type=\"float\"/></accessor></technique_common></source>"
            geo += "<vertices id=\"\(id)-vtx\"><input semantic=\"POSITION\" source=\"#\(id)-pos\"/></vertices>"
            geo += "<triangles material=\"\(mat)\" count=\"\(tris.count)\"><input semantic=\"VERTEX\" source=\"#\(id)-vtx\" offset=\"0\"/><p>"
            geo += indices + "</p></triangles></mesh></geometry>\n"
            geometries += geo
            nodes += "<node id=\"node\(i)\" name=\"\(CNCOut.xmlEscaped(g.part.name))\"><instance_geometry url=\"#\(id)\"><bind_material><technique_common><instance_material symbol=\"\(mat)\" target=\"#\(mat)\"/></technique_common></bind_material></instance_geometry></node>\n"
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><contributor><authoring_tool>WoodShop</authoring_tool></contributor><created>\(iso)</created><modified>\(iso)</modified><unit name="inch" meter="\(unitMeters)"/><up_axis>Z_UP</up_axis></asset>
        <library_effects>
        \(effects)</library_effects>
        <library_materials>
        \(materials)</library_materials>
        <library_geometries>
        \(geometries)</library_geometries>
        <library_visual_scenes><visual_scene id="Scene" name="WoodShop">
        \(nodes)</visual_scene></library_visual_scenes>
        <scene><instance_visual_scene url="#Scene"/></scene>
        </COLLADA>
        """
    }

    /// USD stores meters, Z up (declared in the file).
    static func usdz(_ groups: [(part: Part, faces: [[SIMD3<Double>]])], url: URL) throws {
        let scene = SCNScene()
        for g in groups {
            var verts: [SCNVector3] = [], idx: [UInt32] = []
            for t in triangles(g.faces) { for p in t { idx.append(UInt32(verts.count)); verts.append(SCNVector3(Float(p.x), Float(p.z), Float(-p.y))) } }
            guard !verts.isEmpty else { continue }
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
            let m = SCNMaterial(); m.diffuse.contents = g.part.species.base; geometry.materials = [m]
            let node = SCNNode(geometry: geometry); node.name = safeName(g.part.name)
            scene.rootNode.addChildNode(node)
        }
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw ModelValidation.Failure(message: "USDZ export failed.")
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Document integration

extension Document {
    /// Returns true when the file was handled as a 3D model (successfully or with an error message).
    func importMesh(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard MeshIO.importExtensions.contains(ext) else { return false }
        do {
            // A DXF without 3D faces holds flat outlines: leave it to the 2D importer.
            if ext == "dxf", !(try String(contentsOf: url, encoding: .utf8)).contains("3DFACE") { return false }
            let contents = try MeshIO.read(url)
            var scale = contents.inchesPerUnit ?? 1
            var zUp = contents.zUp ?? true
            var asBoards = true
            if contents.inchesPerUnit == nil || contents.zUp == nil {
                let alert = NSAlert(); alert.messageText = "Import \(url.lastPathComponent)"
                alert.informativeText = "Choose the file's length unit and up axis. Files from SketchUp, CAD and 3D printing tools are usually Z up."
                alert.addButton(withTitle: "Millimeters"); alert.addButton(withTitle: "Inches"); alert.addButton(withTitle: "Cancel")
                let box = NSButton(checkboxWithTitle: "Z axis points up", target: nil, action: nil)
                box.state = zUp ? .on : .off
                let blocks = NSButton(checkboxWithTitle: "Turn rectangular solids into boards (grain along the length)", target: nil, action: nil)
                blocks.state = .on
                let stack = NSStackView(views: [box, blocks]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
                stack.frame = NSRect(x: 0, y: 0, width: 380, height: 44)
                alert.accessoryView = stack
                let answer = alert.runModal()
                if answer == .alertThirdButtonReturn { return true }
                if contents.inchesPerUnit == nil { scale = answer == .alertFirstButtonReturn ? 1 / 25.4 : 1 }
                if contents.zUp == nil { zUp = box.state == .on }
                asBoards = blocks.state == .on
            }
            let result = MeshIO.parts(from: contents, scale: scale, zUp: zUp, baseName: url.deletingPathExtension().lastPathComponent,
                                      boardsFromBlocks: asBoards, defaultSpecies: species.isHardware ? .oak : species)
            guard !result.parts.isEmpty else {
                status = "Nothing imported. " + result.notes.joined(separator: " ")
                return true
            }
            // Land the model on the ground plane beside what is already there.
            var imported = result.parts
            let floor = imported.map { $0.bounds.lo.y }.min() ?? 0
            for i in imported.indices { imported[i].origin.y -= floor }
            if transaction({ parts += imported }) {
                selection = imported.first?.id; selectedIDs = Set(imported.map(\.id))
                status = "Imported \(imported.count) solid(s) from \(url.lastPathComponent). " + result.notes.joined(separator: " ")
            }
        } catch { status = "Import failed: \(error.localizedDescription)" }
        return true
    }

    func exportMesh(_ format: MeshFormat, millimeters: Bool) {
        guard prepareForExport() else { return }
        let exportProject = fabricationSelectionProject
        let list = exportProject.parts
        guard !list.isEmpty else { status = "Nothing to export."; return }
        do { try ModelValidation.validate(exportProject) }
        catch { status = "Export blocked: \(error.localizedDescription)"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = "\(fileName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MeshIO.write(format, parts: list, millimeters: millimeters, url: url)
            status = "Exported \(url.lastPathComponent)"
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }
}
