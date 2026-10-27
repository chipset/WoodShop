import Foundation
import simd

enum ParameterKind: String, Codable, CaseIterable { case length = "Length", scalar = "Number", angle = "Angle" }
struct DesignParameter: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var expression: String
    var kind = ParameterKind.length
    var metricLiterals = false
}
enum BindingTarget: String, Codable, CaseIterable, Identifiable {
    case size = "Part size", position = "Part position", rotation = "Part rotation"
    case cutDepth = "Joint depth", cutWidth = "Joint width", cutOffset = "Joint offset", clearance = "Joint fit clearance"
    case operationDepth = "Machining depth", holeDiameter = "Hole diameter"
    var id: String { rawValue }
}
struct DesignBinding: Codable, Equatable, Identifiable {
    var id = UUID()
    var target: BindingTarget
    var axis = 0
    var feature: UUID? = nil
    var expression: String
    var metricLiterals = false
}
struct Quantity {
    var value: Double
    /// 0 = scalar, 1 = length, 2 = angle. Products of two dimensions are deliberately unsupported.
    var dimension = 0
}
enum Parametric {
    static func values(_ definitions: [DesignParameter]) throws -> [String: Quantity] {
        guard definitions.count <= 1024,Set(definitions.map(\.id)).count == definitions.count else { throw ModelValidation.Failure(message:"Use up to 1,024 uniquely identified named parameters.") }
        var values: [String: Quantity] = [:], resolving: Set<String> = []
        var map: [String: DesignParameter] = [:]
        for definition in definitions {
            let name = definition.name.lowercased()
            guard name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil, map[name] == nil,
                  !["min", "max", "abs", "mm", "in", "cm", "deg"].contains(name) else { throw ModelValidation.Failure(message: "Parameter names must be unique letters/numbers/underscores, starting with a letter.") }
            map[name] = definition
        }
        func resolve(_ name: String) throws -> Quantity {
            if let value = values[name] { return value }
            guard let definition = map[name] else { throw ModelValidation.Failure(message: "Unknown parameter: \(name).") }
            guard resolving.count < 64 else { throw ModelValidation.Failure(message:"Parameter dependencies are too deeply nested. Split the calculation into shorter dependency chains.") }
            guard resolving.insert(name).inserted else { throw ModelValidation.Failure(message: "Parameter cycle includes \(name).") }
            var parser = ExpressionParser(definition.expression, literalScale: definition.metricLiterals ? 1 / 25.4 : 1, lookup: resolve)
            var q = try parser.evaluate()
            let expected = definition.kind == .length ? 1 : (definition.kind == .angle ? 2 : 0)
            if q.dimension == 0 && expected != 0 { q.dimension = expected; if expected == 1 && definition.metricLiterals { q.value /= 25.4 } }
            guard q.dimension == expected else { throw ModelValidation.Failure(message: "\(definition.name) has incompatible units.") }
            values[name] = q; resolving.remove(name)
            return q
        }
        for key in map.keys.sorted() { _ = try resolve(key) }
        return values
    }
    static func evaluate(_ binding: DesignBinding, values: [String: Quantity]) throws -> Double {
        var parser = ExpressionParser(binding.expression, literalScale: binding.metricLiterals ? 1 / 25.4 : 1) { name in
            guard let q = values[name] else { throw ModelValidation.Failure(message: "Unknown parameter: \(name).") }; return q
        }
        var q = try parser.evaluate()
        let expected = binding.target == .rotation ? 2 : 1
        if q.dimension == 0 { q.dimension = expected; if expected == 1 && binding.metricLiterals { q.value /= 25.4 } }
        guard q.dimension == expected else { throw ModelValidation.Failure(message: "The expression has incompatible units for \(binding.target.rawValue).") }
        return q.value
    }
    static func validateBindings(_ part: Part, values: [String: Quantity]) throws {
        var targets: Set<String> = []
        for b in part.bindings ?? [] {
            guard (0..<3).contains(b.axis), targets.insert("\(b.target)|\(b.axis)|\(String(describing:b.feature))").inserted else { throw ModelValidation.Failure(message: "Duplicate or invalid dimension expression.") }
            let expected = try evaluate(b, values: values), actual: Double
            switch b.target {
            case .size: actual = part.size[b.axis]
            case .position: actual = part.origin[b.axis]
            case .rotation: actual = part.rot[b.axis]
            case .cutDepth, .cutWidth, .cutOffset, .clearance:
                guard let cut = part.cuts.first(where: { $0.id == b.feature }) else { throw ModelValidation.Failure(message: "A dimension expression refers to a missing joint.") }
                let a = cut.faceAxis ?? part.materialAxes.t, run = cut.runAxis ?? (0..<3).first { $0 != a }!
                let across = (0..<3).first { $0 != a && $0 != run }!
                if b.target == .cutDepth { actual = cut.hi[a] - cut.lo[a] }
                else if b.target == .cutWidth { actual = cut.hi[across] - cut.lo[across] }
                else if b.target == .clearance { actual = cut.allowance ?? 0 }
                else { actual = cut.offsetFromFar == true ? part.size[across] - cut.hi[across] : cut.lo[across] }
            case .operationDepth, .holeDiameter:
                guard let op = part.operations?.first(where: { $0.id == b.feature }) else { throw ModelValidation.Failure(message: "A dimension expression refers to a missing machining operation.") }
                actual = b.target == .operationDepth ? op.depth : (op.contour.map(\.x).max()! - op.contour.map(\.x).min()!)
            }
            guard abs(actual - expected) <= 1e-6 else { throw ModelValidation.Failure(message: "\(part.name): \(b.target.rawValue) is driven by ‘\(b.expression)’. Edit the named parameter or unlink the expression first.") }
        }
    }
    static func scalar(_ expression: String,values: [String:Quantity]) throws -> Double {
        var parser = ExpressionParser(expression,literalScale:1) { name in guard let value = values[name] else { throw ModelValidation.Failure(message: "Unknown parameter: " + name) }; return value }
        let q = try parser.evaluate()
        guard q.dimension == 0 else { throw ModelValidation.Failure(message:"A pattern count needs a dimensionless number.") }; return q.value
    }
    static func apply(to part: inout Part, values: [String: Quantity], validate: Bool = true) throws {
        if let message = ModelValidation.axes(part) { throw ModelValidation.Failure(message:message) }
        let old = part, bindings = part.bindings ?? []
        for binding in bindings where [.size, .position, .rotation].contains(binding.target) {
            guard (0..<3).contains(binding.axis) else { throw ModelValidation.Failure(message: "Invalid dimension binding axis.") }
            let value = try evaluate(binding, values: values)
            switch binding.target {
            case .size: part.size[binding.axis] = value
            case .position: part.origin[binding.axis] = value
            case .rotation: part.rot[binding.axis] = value
            default: break
            }
        }
        if part.size != old.size { part.adjustJoinery(from: old) }
        for binding in bindings where ![.size, .position, .rotation].contains(binding.target) {
            let value = try evaluate(binding, values: values)
            guard value >= 0 else { throw ModelValidation.Failure(message: "Joint and machining dimensions cannot be negative.") }
            if [.cutWidth, .cutDepth, .cutOffset, .clearance].contains(binding.target) {
                guard let i = part.cuts.firstIndex(where: { $0.id == binding.feature }) else { throw ModelValidation.Failure(message: "The parameter refers to a removed joint.") }
                var cut = part.cuts[i]
                let a = cut.faceAxis ?? part.materialAxes.t
                let run = cut.runAxis ?? (0..<3).first { $0 != a }!, across = (0..<3).first { $0 != a && $0 != run }!
                if binding.target == .clearance { cut.allowance = value }
                if binding.target == .cutWidth { if cut.offsetFromFar == true { cut.lo[across] = cut.hi[across] - value } else { cut.hi[across] = cut.lo[across] + value } }
                if binding.target == .cutOffset {
                    let width = cut.hi[across] - cut.lo[across]
                    if cut.offsetFromFar == true { cut.hi[across] = part.size[across] - value; cut.lo[across] = cut.hi[across] - width }
                    else { cut.lo[across] = value; cut.hi[across] = value + width }
                }
                if binding.target == .cutDepth {
                    if cut.additive { cut.lo[a] = cut.facePositive == true ? part.size[a] : -value; cut.hi[a] = cut.facePositive == true ? part.size[a] + value : 0 }
                    else { cut.lo[a] = cut.facePositive == true ? part.size[a] - value : 0; cut.hi[a] = cut.facePositive == true ? part.size[a] : value }
                }
                part.cuts[i] = cut
            } else {
                guard let i = part.operations?.firstIndex(where: { $0.id == binding.feature }) else { throw ModelValidation.Failure(message: "The parameter refers to a removed machining operation.") }
                if binding.target == .operationDepth { part.operations![i].depth = value }
                else {
                    guard part.operations![i].contour.count >= 3 else { throw ModelValidation.Failure(message:"The hole contour is empty or incomplete.") }
                    let contour = part.operations![i].contour, center = contour.reduce(.zero, +) / Double(contour.count)
                    let diameter = (contour.map(\.x).max()! - contour.map(\.x).min()!)
                    guard diameter > 0 else { throw ModelValidation.Failure(message: "The hole has no diameter.") }
                    part.operations![i].contour = contour.map { center + ($0 - center) * (value / diameter) }
                }
            }
        }
        for i in (part.patterns ?? []).indices { try part.patterns![i].evaluate(values) }
        if validate, let message = ModelValidation.part(part) { throw ModelValidation.Failure(message: part.name + ": " + message) }
    }
}

private struct ExpressionParser {
    var tokens: [String]
    var index = 0
    var depth = 0
    var excessiveLength = false
    var literalScale: Double
    var lookup: (String) throws -> Quantity
    init(_ source: String, literalScale: Double, lookup: @escaping (String) throws -> Quantity) {
        let source = source.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
        self.literalScale = literalScale; self.lookup = lookup
        if source.utf8.count > 8192 { self.tokens = []; self.excessiveLength = true; return }
        let regex = try! NSRegularExpression(pattern: "(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?|[a-zA-Z_][a-zA-Z_0-9]*|[^\\s]")
        self.tokens = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { String(source[Range($0.range, in: source)!]).lowercased() }
        self.literalScale = literalScale; self.lookup = lookup
    }
    mutating func evaluate() throws -> Quantity {
        guard !excessiveLength,tokens.count <= 4096 else { throw ModelValidation.Failure(message:"The expression is too long. Split it into named parameters.") }
        let value = try sum()
        guard index == tokens.count, value.value.isFinite else { throw ModelValidation.Failure(message: "Invalid expression or nonfinite result.") }
        return value
    }
    mutating func consume(_ token: String) -> Bool { if index < tokens.count && tokens[index] == token { index += 1; return true }; return false }
    mutating func sum() throws -> Quantity {
        var lhs = try product()
        while index < tokens.count && ["+", "-"].contains(tokens[index]) {
            let sign = tokens[index] == "+" ? 1.0 : -1; index += 1
            var rhs = try product()
            if lhs.dimension != rhs.dimension {
                if lhs.dimension == 0 { lhs.value *= rhs.dimension == 1 ? literalScale : 1; lhs.dimension = rhs.dimension }
                else if rhs.dimension == 0 { rhs.value *= lhs.dimension == 1 ? literalScale : 1; rhs.dimension = lhs.dimension }
            }
            guard lhs.dimension == rhs.dimension else { throw ModelValidation.Failure(message: "Cannot add lengths and angles.") }
            lhs.value += sign * rhs.value
        }
        return lhs
    }
    mutating func product() throws -> Quantity {
        var lhs = try primary()
        while index < tokens.count && ["*", "/"].contains(tokens[index]) {
            let divide = tokens[index] == "/"; index += 1; let rhs = try primary()
            if divide {
                guard abs(rhs.value) > 1e-15 else { throw ModelValidation.Failure(message: "Division by zero.") }
                guard rhs.dimension == 0 || lhs.dimension == rhs.dimension else { throw ModelValidation.Failure(message: "Incompatible division units.") }
                lhs.value /= rhs.value; if rhs.dimension != 0 { lhs.dimension = 0 }
            } else {
                guard lhs.dimension == 0 || rhs.dimension == 0 else { throw ModelValidation.Failure(message: "Multiply a dimension by a number, not another dimension.") }
                lhs.value *= rhs.value; lhs.dimension = max(lhs.dimension, rhs.dimension)
            }
        }
        return lhs
    }
    mutating func primary() throws -> Quantity {
        guard depth < 128 else { throw ModelValidation.Failure(message:"The expression is too deeply nested.") }
        depth += 1; defer { depth -= 1 }
        if consume("-") { var q = try primary(); q.value = -q.value; return q }
        if consume("+") { return try primary() }
        if consume("(") { let q = try sum(); guard consume(")") else { throw ModelValidation.Failure(message: "Missing closing parenthesis.") }; return q }
        guard index < tokens.count else { throw ModelValidation.Failure(message: "The expression is incomplete.") }
        let token = tokens[index]; index += 1
        if let number = Double(token) {
            if consume("mm") { return Quantity(value: number / 25.4, dimension: 1) }
            if consume("cm") { return Quantity(value: number * 10 / 25.4, dimension: 1) }
            if consume("in") || consume("\"") { return Quantity(value: number, dimension: 1) }
            if consume("deg") || consume("°") { return Quantity(value: number, dimension: 2) }
            return Quantity(value: number)
        }
        if ["min", "max", "abs"].contains(token), consume("(") {
            var a = try sum()
            if token == "abs" { a.value = abs(a.value) }
            else {
                guard consume(",") else { throw ModelValidation.Failure(message: "Use two arguments for \(token).") }
                let b = try sum(); guard a.dimension == b.dimension else { throw ModelValidation.Failure(message: "Function arguments need matching units.") }
                a.value = token == "min" ? min(a.value, b.value) : max(a.value, b.value)
            }
            guard consume(")") else { throw ModelValidation.Failure(message: "Missing function parenthesis.") }; return a
        }
        return try lookup(token)
    }
}

struct DesignSnapshot: Codable, Equatable {
    var parts: [Part]
    var links: [DimensionLink]
    var parameters: [DesignParameter]
    var matingJoints: [MatingJoint]? = nil
    var relations: [AssemblyRelation]? = nil
}
struct HistoryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var name: String
    var snapshot: DesignSnapshot
}
extension Document {
    var designSnapshot: DesignSnapshot { DesignSnapshot(parts: parts, links: links, parameters: studio.parameters ?? [],matingJoints:studio.matingJoints,relations:studio.relations) }
    func recordHistory(_ name: String? = nil) {
        assignShopNumbers()
        let current = designSnapshot
        var entries = studio.history ?? []
        if entries.last?.snapshot == current {
            if let name { entries[entries.count - 1].name = name; studio.history = entries }
            return
        }
        if entries.isEmpty, let historyOrigin, historyOrigin != current { entries.append(HistoryEntry(name: "Before first change", snapshot: historyOrigin)) }
        if entries.isEmpty && parts.isEmpty && (studio.parameters ?? []).isEmpty { return }
        let previous = entries.last?.snapshot
        let label: String
        if let name { label = name }
        else if previous?.parameters != current.parameters { label = "Change design parameters" }
        else if (previous?.parts.count ?? 0) < parts.count { label = "Add parts" }
        else if (previous?.parts.count ?? 0) > parts.count { label = "Remove parts" }
        else { label = "Edit " + (selectedPart?.name ?? "design") }
        entries.append(HistoryEntry(name: label, snapshot: current))
        if entries.count > 80 { entries.removeFirst(entries.count - 80) }
        studio.history = entries
    }
    func restoreHistory(_ entry: HistoryEntry) {
        let success = transaction {
            parts = entry.snapshot.parts; links = entry.snapshot.links; studio.parameters = entry.snapshot.parameters; studio.matingJoints = entry.snapshot.matingJoints;studio.relations = entry.snapshot.relations
            selectedFace = nil; selectedSurface = nil
        }
        if success { recordHistory("Restore: " + entry.name) }
    }
    @discardableResult func setParameters(_ parameters: [DesignParameter]) -> Bool {
        transaction {
            let values = try Parametric.values(parameters)
            for i in parts.indices { try Parametric.apply(to: &parts[i], values: values, validate: false) }
            studio.parameters = parameters
            if let id = parts.first?.id, !propagateLinks(from: id) { throw ModelValidation.Failure(message: "Parameter changes would invalidate linked dimensions.") }
        }
    }
    func bind(_ binding: DesignBinding, to id: UUID) {
        transaction {
            guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
            var bindings = parts[index].bindings ?? []
            bindings.removeAll { $0.target == binding.target && $0.axis == binding.axis && $0.feature == binding.feature }
            bindings.append(binding); parts[index].bindings = bindings
            let values = try Parametric.values(studio.parameters ?? [])
            try Parametric.apply(to: &parts[index], values: values, validate: false)
            if let component = parts[index].component, ![.position, .rotation].contains(binding.target) {
                for j in parts.indices where j != index && parts[j].component == component {
                    var other = parts[j].bindings ?? []
                    other.removeAll { $0.target == binding.target && $0.axis == binding.axis && $0.feature == binding.feature }
                    other.append(binding); parts[j].bindings = other
                    try Parametric.apply(to: &parts[j], values: values, validate: false)
                }
            }
            if !propagateLinks(from: id) { throw ModelValidation.Failure(message: "This expression conflicts with a linked dimension.") }
        }
    }
}
