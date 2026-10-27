import AppKit
import UniformTypeIdentifiers
import simd

struct ImportedGeometry { var contours: [[SIMD2<Double>]]; var notes: [String] = [] }
enum GeometryImport {
    static func points3D(_ text: String, metric: Bool) throws -> [SIMD3<Double>] {
        try text.split(whereSeparator: \.isNewline).map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw ModelValidation.Failure(message: "Each path line needs X,Y,Z.") }
            let values = fields.compactMap { Units.parse(String($0), bareIsMM: metric) }
            guard values.count == 3 else { throw ModelValidation.Failure(message: "Invalid path coordinate.") }
            return SIMD3(values[0], values[1], values[2])
        }
    }
    static func contains(_ point: SIMD2<Double>, polygon: [SIMD2<Double>]) -> Bool {
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
    static func parts(_ geometry: ImportedGeometry, thickness: Double, name: String) throws -> [Part] {
        let contours = geometry.contours.filter { $0.count >= 3 }
        guard !contours.isEmpty else { throw ModelValidation.Failure(message: "No closed faces were found.") }
        for contour in contours { guard Planar.isSimple(contour) else { throw ModelValidation.Failure(message: "An imported contour crosses or touches itself.") } }
        let parents: [Int?] = contours.indices.map { i in
            contours.indices.filter { j in j != i && abs(Planar.signedArea(contours[j])) > abs(Planar.signedArea(contours[i])) && contains(contours[i][0], polygon: contours[j]) }
                .min { abs(Planar.signedArea(contours[$0])) < abs(Planar.signedArea(contours[$1])) }
        }
        func depth(_ index: Int) -> Int { var d = 0, p = parents[index]; while let i = p { d += 1; p = parents[i] }; return d }
        var result: [Part] = []
        for i in contours.indices where depth(i) % 2 == 0 {
            let points = contours[i], lo = points.reduce(points[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }, hi = points.reduce(points[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
            let span = hi - lo
            var part = Part(name: "\(name) \(result.count + 1)", origin: SIMD3(lo.x, 0, lo.y), size: SIMD3(span.x, thickness, span.y), species: .plywood)
            part.thicknessAxis = 1; part.grainDirection = 0
            part.profile = BoardProfile(u: 0, v: 2, nodes: points.map { .init(point: ($0 - lo) / span) })
            part.operations = contours.indices.filter { parents[$0] == i }.map { hole in
                // Face normal Y uses U=Z, V=X.
                MachiningOperation(name: "Imported through cutout", axis: 1, positive: true, depth: thickness,
                    contour: contours[hole].map { SIMD2($0.y - lo.y, $0.x - lo.x) }, kind: "Cutout")
            }
            if let error = ModelValidation.part(part) { throw ModelValidation.Failure(message: error) }
            result.append(part)
        }
        return result
    }
    static func obj(_ text: String, scale: Double) throws -> Part {
        var vertices: [SIMD3<Double>] = [], polygons: [Geo.Poly] = []
        var edges: [String: Int] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let fields = raw.split(whereSeparator: \.isWhitespace)
            guard let command = fields.first else { continue }
            if command == "v" {
                let values = fields.dropFirst().prefix(3).compactMap { Double($0) }
                guard values.count == 3 else { throw ModelValidation.Failure(message: "Invalid OBJ vertex.") }
                vertices.append(SIMD3(values[0], values[1], values[2]) * scale)
            } else if command == "f" {
                let ids = fields.dropFirst().compactMap { Int($0.split(separator: "/", omittingEmptySubsequences: false)[0]) }.map { $0 < 0 ? vertices.count + $0 : $0 - 1 }
                guard ids.count == fields.count - 1, ids.count >= 3, ids.allSatisfy(vertices.indices.contains) else { throw ModelValidation.Failure(message: "Invalid OBJ face index.") }
                let pts = ids.map { vertices[$0] }
                let n = simdNormalize(cross(pts[1] - pts[0], pts[2] - pts[0]))
                let axis = (0..<3).max { abs(n[$0]) < abs(n[$1]) }!, u = (axis + 1) % 3, v = (axis + 2) % 3
                let flat = pts.map { SIMD2($0[u], $0[v]) }
                guard Planar.isSimple(flat) else { throw ModelValidation.Failure(message: "An OBJ face is degenerate or crosses itself.") }
                for tri in Planar.triangulate(flat) {
                    let points = tri.map { pts[flat.firstIndex(of: $0)!] }
                    if let face = SolidCSG.face(points, normal: n) { polygons.append(face) }
                }
                for i in ids.indices { let va = vertices[ids[i]], vb = vertices[ids[(i + 1) % ids.count]]
                    func key(_ p: SIMD3<Double>) -> String { "\((p.x * 1e6).rounded()),\((p.y * 1e6).rounded()),\((p.z * 1e6).rounded())" }
                    let a = key(va), b = key(vb); edges[a < b ? a + "|" + b : b + "|" + a, default: 0] += 1 }
            }
        }
        guard !polygons.isEmpty, edges.values.allSatisfy({ $0 == 2 }) else { throw ModelValidation.Failure(message: "OBJ must contain closed, manifold solids; open surfaces cannot become stock.") }
        let volume = polygons.reduce(0.0) { total, f in total + simd_dot(f.pts[0], cross(f.pts[1], f.pts[2])) / 6 }
        if volume < 0 { polygons = polygons.map { Geo.Poly(pts: $0.pts.reversed(), n: -$0.n) } }
        return try MeshTools.part(polygons: polygons, name: "Imported OBJ")
    }
    static func dxf(_ text: String, fallbackScale: Double) throws -> ImportedGeometry {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var pairs: [(Int, String)] = []
        var i = 0
        while i + 1 < lines.count { if let code = Int(lines[i]) { pairs.append((code, lines[i + 1])) }; i += 2 }
        var scale = fallbackScale
        if let j = pairs.firstIndex(where: { $0.1 == "$INSUNITS" }), j + 1 < pairs.count, let unit = Int(pairs[j + 1].1) {
            if unit == 1 { scale = 1 }; if unit == 4 { scale = 1 / 25.4 }; if unit == 5 { scale = 10 / 25.4 }; if unit == 6 { scale = 1000 / 25.4 }
        }
        var result = ImportedGeometry(contours: []), poly: [SIMD2<Double>] = [], closed = false
        var groups: [(String, [(Int,String)])] = []
        for pair in pairs {
            if pair.0 == 0 { groups.append((pair.1, [])) }
            else if !groups.isEmpty { groups[groups.count - 1].1.append(pair) }
        }
        func value(_ group: [(Int,String)], _ code: Int, _ defaultValue: Double = 0) -> Double { group.first { $0.0 == code }.flatMap { Double($0.1) } ?? defaultValue }
        for (type, group) in groups {
            switch type {
            case "POLYLINE": poly = []; closed = Int(value(group, 70)) & 1 == 1
            case "VERTEX":
                if abs(value(group, 42)) > 1e-9 { throw ModelValidation.Failure(message: "DXF bulged polylines are unsupported. Convert arcs to polylines before import.") }
                poly.append(SIMD2(value(group, 10), value(group, 20)) * scale)
            case "SEQEND": if closed && poly.count >= 3 { result.contours.append(poly) }; poly = []
            case "LWPOLYLINE":
                var pts: [SIMD2<Double>] = [], x: Double?
                for pair in group {
                    if pair.0 == 42, let bulge = Double(pair.1), abs(bulge) > 1e-9 { throw ModelValidation.Failure(message: "Convert DXF bulges to polylines before importing.") }
                    if pair.0 == 10 { x = Double(pair.1) }
                    if pair.0 == 20, let x, let y = Double(pair.1) { pts.append(SIMD2(x,y) * scale) }
                }
                if Int(value(group, 70)) & 1 == 1 { result.contours.append(pts) } else { result.notes.append("Skipped open DXF polyline.") }
            case "CIRCLE": result.contours.append(MeshTools.circle(center: SIMD2(value(group,10), value(group,20)) * scale, radius: value(group,40) * scale, segments: 96))
            case "LINE", "ARC", "SPLINE", "INSERT": result.notes.append("Skipped unsupported DXF \(type).")
            default: break
            }
        }
        return result
    }
    static func svg(_ data: Data) throws -> ImportedGeometry {
        let delegate = SVGReader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.error == nil else { throw ModelValidation.Failure(message: delegate.error ?? "Invalid SVG XML.") }
        return ImportedGeometry(contours: delegate.contours, notes: delegate.notes)
    }
}

private final class SVGReader: NSObject, XMLParserDelegate {
    var contours: [[SIMD2<Double>]] = [], notes: [String] = [], error: String?
    var transforms: [CGAffineTransform] = [.identity]
    var unitScale = 1 / 96.0
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String:String]) {
        var transform = transforms.last!
        if element == "svg" {
            let view = numbers(a["viewBox"] ?? "")
            if view.count == 4, let width = a["width"], let inches = length(width) { unitScale = inches / view[2] }
        }
        if let raw = a["transform"] {
            do { transform = try parseTransform(raw).concatenating(transform) }
            catch { self.error = error.localizedDescription }
        }
        transforms.append(transform)
        func number(_ key: String, _ fallback: Double = 0) -> Double { Double(a[key] ?? "") ?? fallback }
        var paths: [[SIMD2<Double>]] = []
        switch element {
        case "path":
            do { paths = try SVGPath.parse(a["d"] ?? "") } catch { self.error = error.localizedDescription }
        case "polygon":
            let values = numbers(a["points"] ?? ""); if values.count % 2 == 0 { paths = [stride(from: 0, to: values.count, by: 2).map { SIMD2(values[$0], values[$0 + 1]) }] }
        case "rect":
            let x = number("x"), y = number("y"), w = number("width"), h = number("height")
            if number("rx") != 0 || number("ry") != 0 { error = "Convert rounded SVG rectangles to paths before import." }
            paths = [[SIMD2(x,y), SIMD2(x+w,y), SIMD2(x+w,y+h), SIMD2(x,y+h)]]
        case "circle", "ellipse":
            let rx = number(element == "circle" ? "r" : "rx"), ry = element == "circle" ? rx : number("ry")
            paths = [MeshTools.circle(center: .zero, radius: 1, segments: 96).map { SIMD2(number("cx") + $0.x * rx, number("cy") + $0.y * ry) }]
        case "use", "image", "polyline", "line": notes.append("Skipped SVG \(element).")
        default: break
        }
        for path in paths where path.count >= 3 {
            contours.append(path.map { p in let q = CGPoint(x: p.x, y: p.y).applying(transform); return SIMD2(q.x * unitScale, -q.y * unitScale) })
        }
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { if transforms.count > 1 { transforms.removeLast() } }
    private func length(_ raw: String) -> Double? {
        if raw.hasSuffix("px") { return Double(raw.dropLast(2)).map { $0 / 96 } }
        if raw.hasSuffix("pt") { return Double(raw.dropLast(2)).map { $0 / 72 } }
        if let number = Double(raw) { return number / 96 }
        return Units.parse(raw)
    }
    private func numbers(_ raw: String) -> [Double] { SVGPath.tokens(raw).compactMap(Double.init) }
    private func parseTransform(_ text: String) throws -> CGAffineTransform {
        let regex = try NSRegularExpression(pattern: "([a-zA-Z]+)\\s*\\(([^)]*)\\)")
        var t = CGAffineTransform.identity
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(match.range(at: 1), in: text)!]), v = numbers(String(text[Range(match.range(at: 2), in: text)!]))
            let next: CGAffineTransform
            switch name {
            case "translate" where (1...2).contains(v.count): next = CGAffineTransform(translationX: v[0], y: v.count > 1 ? v[1] : 0)
            case "scale" where (1...2).contains(v.count): next = CGAffineTransform(scaleX: v[0], y: v.count > 1 ? v[1] : v[0])
            case "rotate" where v.count == 1: next = CGAffineTransform(rotationAngle: v[0] * .pi / 180)
            case "matrix" where v.count == 6: next = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            default: throw ModelValidation.Failure(message: "Unsupported SVG transform: \(name).")
            }
            t = next.concatenating(t)
        }
        return t
    }
}

enum SVGPath {
    static func tokens(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "[a-zA-Z]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }
    }
    static func parse(_ text: String) throws -> [[SIMD2<Double>]] {
        let tokens = tokens(text)
        var i = 0, command = "", point = SIMD2<Double>.zero, start = point
        var path: [SIMD2<Double>] = [], result: [[SIMD2<Double>]] = []
        func number() throws -> Double { guard i < tokens.count, let n = Double(tokens[i]), n.isFinite else { throw ModelValidation.Failure(message: "Invalid SVG path coordinate.") }; i += 1; return n }
        func pair(_ relative: Bool) throws -> SIMD2<Double> { let p = SIMD2(try number(), try number()); return relative ? point + p : p }
        while i < tokens.count {
            if Double(tokens[i]) == nil { command = tokens[i]; i += 1 }
            let relative = command == command.lowercased()
            switch command.uppercased() {
            case "M":
                point = try pair(relative); start = point; path = [point]; command = relative ? "l" : "L"
            case "L": point = try pair(relative); path.append(point)
            case "H": point.x = try number() + (relative ? point.x : 0); path.append(point)
            case "V": point.y = try number() + (relative ? point.y : 0); path.append(point)
            case "C", "Q":
                let a = point, control = try pair(relative)
                let b: SIMD2<Double>, c: SIMD2<Double>
                if command.uppercased() == "C" { b = try pair(relative); c = try pair(relative) }
                else { c = try pair(relative); b = c + (control - c) * 2 / 3 }
                let first = command.uppercased() == "C" ? control : a + (control - a) * 2 / 3
                for step in 1...48 { let t = Double(step) / 48, u = 1 - t; path.append(a * (u*u*u) + first * (3*u*u*t) + b * (3*u*t*t) + c * (t*t*t)) }
                point = c
            case "Z":
                if path.last.map({ simd_length($0 - start) < 1e-8 }) == true { path.removeLast() }
                if path.count >= 3 { result.append(path) }; path = []; point = start; command = ""
            default: throw ModelValidation.Failure(message: "Unsupported or open SVG path command \(command). Convert arcs to cubic paths first.")
            }
        }
        if !path.isEmpty { throw ModelValidation.Failure(message: "SVG paths must be closed with Z.") }
        return result
    }
}

extension Document {
    func importGeometry() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = (["svg"] + MeshIO.importExtensions).compactMap { UTType(filenameExtension: $0) }; panel.allowsMultipleSelection = false
        panel.message = "3D models: STL, OBJ, PLY, 3DS, DAE, KMZ, USD/USDZ, DXF 3D faces. Flat outlines: SVG, DXF."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if importMesh(url) { return }
        do {
            let data = try Data(contentsOf: url), ext = url.pathExtension.lowercased()
            var scale = 1.0
            if ext != "svg" {
                let alert = NSAlert(); alert.messageText = "Import units"
                alert.informativeText = "Choose the coordinate units. DXF unit metadata takes precedence when present."
                alert.addButton(withTitle: "Millimeters"); alert.addButton(withTitle: "Inches"); alert.addButton(withTitle: "Cancel")
                let answer = alert.runModal(); if answer == .alertThirdButtonReturn { return }; scale = answer == .alertFirstButtonReturn ? 1 / 25.4 : 1
            }
            var imported: [Part], notes: [String] = []
            if ext == "obj" { imported = [try GeometryImport.obj(String(decoding: data, as: UTF8.self), scale: scale)] }
            else {
                let geometry = ext == "svg" ? try GeometryImport.svg(data) : try GeometryImport.dxf(String(decoding: data, as: UTF8.self), fallbackScale: scale)
                imported = try GeometryImport.parts(geometry, thickness: rectThickness, name: url.deletingPathExtension().lastPathComponent); notes = geometry.notes
            }
            if transaction({ parts += imported }) {
                selection = imported.first?.id; selectedIDs = Set(imported.map(\.id))
                status = "Imported \(imported.count) part(s). " + Array(Set(notes)).joined(separator: " ")
            }
        } catch { status = "Import failed: \(error.localizedDescription)" }
    }
}
