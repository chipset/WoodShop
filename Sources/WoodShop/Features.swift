import Foundation
import CryptoKit
import simd

enum FeatureKind: String, Codable, CaseIterable { case cut, operation, pattern, trim }
struct FeatureStep: Codable, Equatable, Hashable, Identifiable {
    var kind: FeatureKind
    var feature: UUID
    var id: String { kind.rawValue + feature.uuidString }
}
struct FeatureRef: Codable, Equatable, Hashable, Identifiable {
    var part: UUID
    var kind: FeatureKind
    var feature: UUID
    var id: String { part.uuidString + kind.rawValue + feature.uuidString }
}
struct HistoryInspection: Equatable { var part: UUID; var through: Int }

enum PatternLayout: String, Codable, CaseIterable { case grid = "Grid / line", circular = "Circular" }
enum PatternPlacement: String, Codable, CaseIterable { case fixed = "From minimum corner", margins = "Edge margins", centered = "Centered" }
enum HeadRecess: String, Codable, CaseIterable { case none = "None", counterbore = "Counterbore", countersink = "Countersink" }
enum PatternField: String, Codable, CaseIterable, Identifiable {
    case columns = "Columns / holes", rows = "Rows", diameter = "Diameter", depth = "Depth"
    case pitchU = "Pitch U", pitchV = "Pitch V", marginU = "Margin U", marginV = "Margin V", radius = "Radius"
    var id: String { rawValue }
    var count: Bool { self == .columns || self == .rows }
}
struct PatternExpression: Codable, Equatable, Identifiable {
    var field: PatternField
    var expression: String
    var metricLiterals = false
    var id: String { field.rawValue }
}
struct DrillingPattern: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Drilling pattern"
    var axis = 1
    var positive = true
    var layout = PatternLayout.grid
    var placement = PatternPlacement.margins
    var origin = SIMD2<Double>(1,1)
    var margin = SIMD2<Double>(1,1)
    var pitch = SIMD2<Double>(2,2)
    var columns = 1
    var rows = 1
    var spanU = false
    var spanV = false
    var farU = false
    var farV = false
    var radius = 2.0
    var diameter = 0.25
    var depth = 0.5
    var through = false
    var recess = HeadRecess.none
    var recessDiameter = 0.5
    var recessDepth = 0.125
    var includedAngle = 82.0
    var suppressed = false
    var expressions: [PatternExpression]? = nil
    var startAngle: Double? = nil
    var hardwareTemplateID: UUID? = nil
    var u: Int { (axis + 1) % 3 }
    var v: Int { (axis + 2) % 3 }

    func generated(size: SIMD3<Double>) throws -> [MachiningOperation] {
        guard (0..<3).contains(axis), (1...100).contains(columns), (1...100).contains(rows),
              (layout == .circular ? columns : columns * rows) <= 100,
              origin.x.isFinite, origin.y.isFinite, margin.x.isFinite, margin.y.isFinite,
              pitch.x.isFinite, pitch.y.isFinite, pitch.x >= 0, pitch.y >= 0,
              radius.isFinite, radius > 0, margin.x >= 0, margin.y >= 0 else {
            throw ModelValidation.Failure(message: name + ": use up to 100 holes and finite, nonnegative spacing/margins.")
        }
        if let angle = startAngle,!angle.isFinite { throw ModelValidation.Failure(message:name + ": invalid circular pattern angle.") }
        if recess != .none {
            guard recessDiameter.isFinite,recessDiameter > diameter,recessDepth.isFinite,recessDepth > 0,includedAngle.isFinite else { throw ModelValidation.Failure(message:name + ": choose a head diameter larger than the hole and a positive recess depth.") }
        }
        guard diameter.isFinite,diameter > 0,depth.isFinite,depth > 0 else { throw ModelValidation.Failure(message:name + ": hole diameter and depth must be positive and finite.") }
        if suppressed { return [] }
        var step = pitch
        if spanU && columns > 1 { step.x = (size[u] - 2 * margin.x) / Double(columns - 1) }
        if spanV && rows > 1 { step.y = (size[v] - 2 * margin.y) / Double(rows - 1) }
        guard step.x >= 0, step.y >= 0 else { throw ModelValidation.Failure(message: name + ": margins leave no room for the pattern.") }
        let extent = SIMD2(Double(columns - 1) * step.x, Double(rows - 1) * step.y)
        let start: SIMD2<Double>
        switch placement {
        case .fixed: start = origin
        case .margins: start = margin
        case .centered: start = (SIMD2(size[u],size[v]) - extent) / 2
        }
        var centers: [(String,SIMD2<Double>)] = []
        if layout == .circular {
            let center = placement == .centered ? SIMD2(size[u],size[v]) / 2 : start
            for i in 0..<columns { let a = 2 * Double.pi * Double(i) / Double(columns) + (startAngle ?? 0) * .pi / 180
                var point = center + radius * SIMD2(cos(a),sin(a))
                if farU { point.x = size[u]-point.x }; if farV { point.y = size[v]-point.y }
                centers.append(("circle\(i)",point)) }
        } else {
            for row in 0..<rows { for col in 0..<columns {
                var p = start + SIMD2(Double(col) * step.x,Double(row) * step.y)
                if farU { p.x = size[u] - p.x }; if farV { p.y = size[v] - p.y }
                centers.append(("r\(row)c\(col)",p))
            } }
        }
        var dummy = Part(name:name,origin:.zero,size:size,species:.plywood)
        dummy.thicknessAxis = axis
        var result: [MachiningOperation] = []
        for (key,center) in centers {
            let operations = try JoineryTools.holes(part:dummy,axis:axis,positive:positive,centers:[center],diameter:diameter,
                depth:through ? size[axis] : depth,counterDiameter:recess == .none ? 0 : recessDiameter,
                counterDepth:recessDepth,countersinkAngle:recess == .countersink ? includedAngle : nil)
            for (index,var op) in operations.enumerated() {
                op.id = Self.stableID(id,key + "op\(index)"); op.patternID = id
                op.name = name + " · " + key + (index == 0 ? "" : " · " + recess.rawValue)
                result.append(op)
            }
        }
        return result
    }
    static func stableID(_ seed: UUID, _ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data:Data((seed.uuidString + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128
        return UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    mutating func evaluate(_ values: [String: Quantity]) throws {
        for binding in expressions ?? [] {
            let value: Double
            if binding.field.count { value = try Parametric.scalar(binding.expression,values:values) }
            else { value = try Parametric.evaluate(DesignBinding(target:.size,expression:binding.expression,metricLiterals:binding.metricLiterals),values:values) }
            if binding.field.count, value.rounded() != value || value < 1 || value > 100 { throw ModelValidation.Failure(message: name + ": hole counts must be whole numbers from 1 to 100.") }
            switch binding.field {
            case .columns: columns = Int(value)
            case .rows: rows = Int(value)
            case .diameter: diameter = value
            case .depth: depth = value
            case .pitchU: pitch.x = value
            case .pitchV: pitch.y = value
            case .marginU: margin.x = value
            case .marginV: margin.y = value
            case .radius: radius = value
            }
        }
    }
}

extension Part {
    var machiningOperations: [MachiningOperation] {
        (operations ?? []) + (patterns ?? []).flatMap { (try? $0.generated(size:size)) ?? [] }
    }
    func featureName(_ step: FeatureStep) -> String {
        switch step.kind {
        case .cut: return cuts.first { $0.id == step.feature }.map { $0.name ?? $0.kind } ?? "Removed joint"
        case .operation: return operations?.first { $0.id == step.feature }?.name ?? "Removed operation"
        case .pattern: return patterns?.first { $0.id == step.feature }?.name ?? "Removed pattern"
        case .trim: return "Angled cut"
        }
    }
    var featureSteps: [FeatureStep] {
        let available = cuts.map { FeatureStep(kind:.cut,feature:$0.id) }
            + (operations ?? []).map { FeatureStep(kind:.operation,feature:$0.id) }
            + (patterns ?? []).map { FeatureStep(kind:.pattern,feature:$0.id) }
            + trims.map { FeatureStep(kind:.trim,feature:$0.id) }
        let present = Set(available)
        let saved = (featureOrder ?? []).filter(present.contains)
        return saved + available.filter { !saved.contains($0) }
    }
    func toolPolygons(_ step: FeatureStep) -> [Geo.Poly] {
        switch step.kind {
        case .cut:
            guard let c = cuts.first(where: { $0.id == step.feature }), c.suppressed != true else { return [] }
            if c.planes != nil { return Geo.polys(boxes:[Box(lo:c.lo,hi:c.hi)],planes:c.planes!.map { ($0.p,$0.n) }) }
            return c.additive ? Geo.polys(boxes:[Box(lo:c.lo,hi:c.hi)],planes:[]) : c.machiningPolygons(part:self)
        case .operation:
            guard let op = operations?.first(where: { $0.id == step.feature }), op.suppressed != true else { return [] }
            return op.polygons(size:size)
        case .pattern: return (try? patterns?.first(where: { $0.id == step.feature })?.generated(size:size))?.flatMap { $0.polygons(size:size) } ?? []
        case .trim: return []
        }
    }
}

enum FeatureReplay {
    static func polygons(_ part: Part, through: Int? = nil) -> [Geo.Poly] {
        var result = part.mesh?.polygons(size:part.size) ?? part.profile.map { SolidCSG.extrusion($0,size:part.size) }
            ?? Geo.polys(boxes:[Box(lo:.zero,hi:part.size)],planes:[])
        let steps = part.featureSteps
        let active = through.map { Array(steps.prefix(max(0,min($0,steps.count)))) } ?? steps
        for step in active {
            if step.kind == .trim {
                guard let trim = part.trims.first(where: { $0.id == step.feature }),trim.suppressed != true else { continue }
                var q = part; q.trims = [trim]
                let reach = max(1000,norm(part.size) * 4)
                let tool = Geo.polys(boxes:[Box(lo:SIMD3(repeating:-reach),hi:SIMD3(repeating:reach))],planes:q.trimPlanes)
                    .map { p -> Geo.Poly in var p = p; p.source = step.feature; return p }
                result = SolidCSG.intersection(result,tool)
            } else if step.kind == .pattern {
                guard let pattern = part.patterns?.first(where: { $0.id == step.feature }) else { continue }
                let operations = (try? pattern.generated(size:part.size)) ?? []
                let bounds = operations.map(\.openingBounds)
                let disjoint = bounds.indices.allSatisfy { i in
                    bounds.indices.allSatisfy { j in
                        j <= i || abs(bounds[i].center.x-bounds[j].center.x) > (bounds[i].span.x+bounds[j].span.x)/2+1e-7
                            || abs(bounds[i].center.y-bounds[j].center.y) > (bounds[i].span.y+bounds[j].span.y)/2+1e-7
                    }
                }
                func tool(_ operation: MachiningOperation) -> [Geo.Poly] {
                    operation.polygons(size:part.size).map { p -> Geo.Poly in var p = p; p.source = step.feature; return p }
                }
                // Disconnected, nonintersecting cutters form one solid set. Subtract it once rather
                // than rebuilding an increasingly fragmented board for every hole in a pin row.
                if disjoint { result = SolidCSG.subtract(result,operations.flatMap(tool)) }
                else { for operation in operations { result = SolidCSG.subtract(result,tool(operation)) } }
            } else {
                let tool = part.toolPolygons(step).map { p -> Geo.Poly in var p = p; p.source = step.feature; return p }
                let additive = step.kind == .cut && part.cuts.first(where: { $0.id == step.feature })?.additive == true
                result = additive ? SolidCSG.union(result,tool) : SolidCSG.subtract(result,tool)
            }
        }
        let edgePlanes = part.edgePlanes
        if through == nil, !edgePlanes.isEmpty {
            let reach = max(1000,norm(part.size) * 4)
            result = SolidCSG.intersection(result,Geo.polys(boxes:[Box(lo:SIMD3(repeating:-reach),hi:SIMD3(repeating:reach))],planes:edgePlanes))
        }
        return result
    }
    static func validate(_ part: Part) throws {
        if let order = part.featureOrder, Set(order).count != order.count { throw ModelValidation.Failure(message: part.name + ": feature history contains duplicate steps.") }
        for (index,step) in part.featureSteps.enumerated() {
            let prefix = "\(part.name), step \(index + 1) ‘\(part.featureName(step))’: "
            switch step.kind {
            case .pattern:
                do { _ = try part.patterns!.first { $0.id == step.feature }!.generated(size:part.size) }
                catch { throw ModelValidation.Failure(message:prefix + error.localizedDescription) }
            case .operation:
                if let op = part.operations?.first(where: { $0.id == step.feature }),op.suppressed != true,let message = op.validation(size:part.size) { throw ModelValidation.Failure(message:prefix + message) }
            case .cut:
                if let cut = part.cuts.first(where: { $0.id == step.feature }),cut.suppressed != true,cut.mateID == nil,cut.planes == nil,let axis = cut.faceAxis,!cut.additive,(0..<3).contains(axis),cut.hi[axis]-cut.lo[axis] > part.size[axis]+1e-6 {
                    throw ModelValidation.Failure(message:prefix + "pocket depth exceeds the stock thickness. Edit the depth or suppress this feature.")
                }
            case .trim: break
            }
        }
        if let message = ModelValidation.part(part) { throw ModelValidation.Failure(message: part.name + ": " + message) }

    }
}

extension DrillingPattern {
    func rotated90(axis k:Int,part:Part) -> DrillingPattern {
        let a = (k+1)%3,b = (k+2)%3
        func remap(_ i:Int)->Int { i == a ? b : (i == b ? a : i) }
        var n = self; n.axis = remap(axis)
        if axis == b { n.positive.toggle() }
        let swaps = remap(u) != n.u
        if swaps {
            n.origin = SIMD2(origin.y,origin.x); n.margin = SIMD2(margin.y,margin.x); n.pitch = SIMD2(pitch.y,pitch.x)
            n.spanU = spanV; n.spanV = spanU; n.farU = farV; n.farV = farU
            if layout == .grid { n.columns = rows; n.rows = columns } else { n.startAngle = 90-(startAngle ?? 0) }
            n.expressions = expressions?.map { expression in
                var e = expression
                switch e.field {
                case .columns: if layout == .grid { e.field = .rows }
                case .rows: if layout == .grid { e.field = .columns }
                case .pitchU: e.field = .pitchV
                case .pitchV: e.field = .pitchU
                case .marginU: e.field = .marginV
                case .marginV: e.field = .marginU
                default: break
                }; return e
            }
        }
        if u == b { if remap(u) == n.u { n.farU.toggle() } else { n.farV.toggle() } }
        if v == b { if remap(v) == n.u { n.farU.toggle() } else { n.farV.toggle() } }
        return n
    }
    func reflected(axis:Int) -> DrillingPattern {
        var n = self
        if self.axis == axis { n.positive.toggle() }
        if u == axis { n.farU.toggle() }; if v == axis { n.farV.toggle() }
        return n
    }
}
