import AppKit
import Combine
import UniformTypeIdentifiers
import simd

// MARK: - Materials & stock

enum Species: String, Codable, CaseIterable, Identifiable {
    case oak = "Red Oak", maple = "Hard Maple", cherry = "Cherry", walnut = "Walnut"
    case pine = "Pine", poplar = "Poplar", plywood = "Plywood", mdf = "MDF"
    case steel = "Steel", brass = "Brass"
    var id: String { rawValue }
    var isSheet: Bool { self == .plywood || self == .mdf }
    var isHardware: Bool { self == .steel || self == .brass }
    /// Materials a board can be made from (excludes hardware metals).
    static var woods: [Species] { allCases.filter { !$0.isHardware } }
    /// Tangential (flat-sawn) movement per 1% change in moisture content, in/in.
    var movementPerPercentMC: Double {
        switch self {
        case .oak: return 0.00287
        case .maple: return 0.00330
        case .cherry: return 0.00237
        case .walnut: return 0.00260
        case .pine: return 0.00203
        case .poplar: return 0.00273
        default: return 0
        }
    }
    var base: NSColor {
        switch self {
        case .oak: return NSColor(deviceRed: 0.78, green: 0.60, blue: 0.38, alpha: 1)
        case .maple: return NSColor(deviceRed: 0.88, green: 0.76, blue: 0.58, alpha: 1)
        case .cherry: return NSColor(deviceRed: 0.66, green: 0.38, blue: 0.24, alpha: 1)
        case .walnut: return NSColor(deviceRed: 0.36, green: 0.24, blue: 0.16, alpha: 1)
        case .pine: return NSColor(deviceRed: 0.89, green: 0.74, blue: 0.46, alpha: 1)
        case .poplar: return NSColor(deviceRed: 0.80, green: 0.78, blue: 0.60, alpha: 1)
        case .plywood: return NSColor(deviceRed: 0.86, green: 0.72, blue: 0.50, alpha: 1)
        case .mdf: return NSColor(deviceRed: 0.67, green: 0.55, blue: 0.40, alpha: 1)
        case .steel: return NSColor(deviceRed: 0.62, green: 0.64, blue: 0.67, alpha: 1)
        case .brass: return NSColor(deviceRed: 0.80, green: 0.64, blue: 0.25, alpha: 1)
        }
    }
}

/// Lumber sizes are actual (dressed) dimensions in inches.
struct Stock: Identifiable, Hashable {
    let name: String
    let thickness: Double
    let width: Double
    let length: Double
    var sheet = false
    var hardware: Species? = nil
    var id: String { name }

    static let all: [Stock] = [
        Stock(name: "1x2", thickness: 0.75, width: 1.5, length: 48),
        Stock(name: "1x3", thickness: 0.75, width: 2.5, length: 48),
        Stock(name: "1x4", thickness: 0.75, width: 3.5, length: 48),
        Stock(name: "1x6", thickness: 0.75, width: 5.5, length: 48),
        Stock(name: "1x8", thickness: 0.75, width: 7.25, length: 48),
        Stock(name: "1x12", thickness: 0.75, width: 11.25, length: 48),
        Stock(name: "2x2", thickness: 1.5, width: 1.5, length: 48),
        Stock(name: "2x4", thickness: 1.5, width: 3.5, length: 48),
        Stock(name: "2x6", thickness: 1.5, width: 5.5, length: 48),
        Stock(name: "2x8", thickness: 1.5, width: 7.25, length: 48),
        Stock(name: "4x4", thickness: 3.5, width: 3.5, length: 48),
        Stock(name: "4/4 Hardwood (13/16)", thickness: 0.8125, width: 5.5, length: 48),
        Stock(name: "8/4 Hardwood (1-3/4)", thickness: 1.75, width: 5.5, length: 48),
        Stock(name: "Plywood 3/4 (4x8)", thickness: 0.75, width: 48, length: 96, sheet: true),
        Stock(name: "Plywood 1/2 (4x8)", thickness: 0.5, width: 48, length: 96, sheet: true),
        Stock(name: "Plywood 1/4 (4x8)", thickness: 0.25, width: 48, length: 96, sheet: true),
        Stock(name: "Hinge 3in butt", thickness: 0.09, width: 0.75, length: 3, hardware: .brass),
        Stock(name: "Drawer slide 18in", thickness: 0.5, width: 1.75, length: 18, hardware: .steel),
        Stock(name: "Bar pull 4in", thickness: 0.5, width: 0.75, length: 4, hardware: .steel),
        Stock(name: "Knob 1-1/4in", thickness: 1.25, width: 1.25, length: 1.25, hardware: .brass),
        Stock(name: "Corner brace 3in", thickness: 0.1, width: 0.75, length: 3, hardware: .steel),
        Stock(name: "Screw #8 x 1-1/4", thickness: 0.164, width: 0.164, length: 1.25, hardware: .steel),
        Stock(name: "Shelf pin", thickness: 0.2, width: 0.2, length: 0.75, hardware: .steel),
    ]
}

// MARK: - Parts

/// A half-space boundary in board-local space. Material is kept where n·(x−p) ≤ 0 (n is a unit outward normal).
struct Plane: Codable, Equatable {
    var p: SIMD3<Double>
    var n: SIMD3<Double>
}

/// Chamfer, roundover or arch along an edge, built from tangent clip planes.
struct EdgeProfile: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case chamfer, roundover, arch }
    var id = UUID()
    var kind: Kind
    var axis1: Int
    var pos1: Bool
    /// Second face of the edge; for an arch this is the run axis (pos2 unused).
    var axis2: Int
    var pos2: Bool
    /// Chamfer leg, roundover radius, or arch rise.
    var size: Double
}

/// A rectangular void removed from a part. Coordinates are relative to the part's min corner.
/// When `planes` is set the void is the box intersected with those half-spaces (angled pocket-hole bores).
struct Cut: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: String
    var lo: SIMD3<Double>
    var hi: SIMD3<Double>
    var faceAxis: Int? = nil
    var facePositive: Bool? = nil
    var runAxis: Int? = nil
    var relief: CornerRelief? = nil
    var allowance: Double? = nil
    var suppressed: Bool? = nil
    var offsetFromFar: Bool? = nil
    var mateID: UUID? = nil
    var name: String? = nil
    var planes: [Plane]? = nil
    /// Tenons add material (and may extend outside the board's box); everything else removes it.
    var additive: Bool { kind == "Tenon" }
}

/// An angled end cut (miter or bevel): the face's normal is tilted about `run`, pivoting on one edge.
struct Trim: Codable, Identifiable, Equatable {
    var id = UUID()
    var axis: Int
    var positive: Bool
    var run: Int
    var angle: Double
    /// The edge the long point sits on: far (max) across-edge instead of near (min).
    var farEdge: Bool
    var suppressed: Bool? = nil
}

/// An axis-aligned board. Y is up. `origin` is the min corner, all units inches.
struct Part: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var origin: SIMD3<Double>
    var size: SIMD3<Double>
    var species: Species
    var cuts: [Cut] = []
    /// Euler rotation in degrees about X, Y, Z, applied about the board's centre.
    var rot = SIMD3<Double>.zero
    var trims: [Trim] = []
    var thicknessAxis: Int? = nil
    var grainDirection: Int? = nil
    var group: String? = nil
    var hidden: Bool? = nil
    var resizeJoinery: Bool? = nil
    var profile: BoardProfile? = nil
    var operations: [MachiningOperation]? = nil
    var mesh: MeshSolid? = nil
    var component: UUID? = nil
    var hardware: Bool? = nil
    var allowNestingRotation: Bool? = nil
    var bindings: [DesignBinding]? = nil
    var cncTopPositive: Bool? = nil
    var patterns: [DrillingPattern]? = nil
    var featureOrder: [FeatureStep]? = nil
    var shopNumber: Int? = nil
    var toolAssignments: [String:UUID]? = nil
    var shop: PartShopData? = nil
    var edges: [EdgeProfile]? = nil

    var materialAxes: (t: Int, w: Int, l: Int) {
        let t = thicknessAxis ?? (0..<3).min { size[$0] < size[$1] }!
        let remaining = (0..<3).filter { $0 != t }
        let l = grainDirection.flatMap { remaining.contains($0) ? $0 : nil }
            ?? remaining.max { size[$0] < size[$1] }!
        return (t, remaining.first { $0 != l }!, l)
    }

    var isRotated: Bool { rot != .zero }
    var hi: SIMD3<Double> { origin + size }
    var center: SIMD3<Double> { origin + size / 2 }
    /// Grain runs along the longest dimension.
    var grainAxis: Int {
        if let grainDirection { return grainDirection }
        if size.x >= size.y && size.x >= size.z { return 0 }
        return size.y >= size.z ? 1 : 2
    }
}

extension Part {
    enum CodingKeys: String, CodingKey { case id, name, origin, size, species, cuts, rot, trims, thicknessAxis, grainDirection, group, hidden, resizeJoinery, profile, operations, mesh, component, hardware, allowNestingRotation, bindings, cncTopPositive, patterns, featureOrder, shopNumber, toolAssignments, shop, edges }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        origin = try c.decode(SIMD3<Double>.self, forKey: .origin)
        size = try c.decode(SIMD3<Double>.self, forKey: .size)
        species = try c.decode(Species.self, forKey: .species)
        cuts = try c.decodeIfPresent([Cut].self, forKey: .cuts) ?? []
        rot = try c.decodeIfPresent(SIMD3<Double>.self, forKey: .rot) ?? .zero
        trims = try c.decodeIfPresent([Trim].self, forKey: .trims) ?? []
        thicknessAxis = try c.decodeIfPresent(Int.self, forKey: .thicknessAxis)
        grainDirection = try c.decodeIfPresent(Int.self, forKey: .grainDirection)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
        resizeJoinery = try c.decodeIfPresent(Bool.self, forKey: .resizeJoinery)
        profile = try c.decodeIfPresent(BoardProfile.self, forKey: .profile)
        operations = try c.decodeIfPresent([MachiningOperation].self, forKey: .operations)
        mesh = try c.decodeIfPresent(MeshSolid.self, forKey: .mesh)
        component = try c.decodeIfPresent(UUID.self, forKey: .component)
        hardware = try c.decodeIfPresent(Bool.self, forKey: .hardware)
        allowNestingRotation = try c.decodeIfPresent(Bool.self, forKey: .allowNestingRotation)
        bindings = try c.decodeIfPresent([DesignBinding].self, forKey: .bindings)
        cncTopPositive = try c.decodeIfPresent(Bool.self, forKey: .cncTopPositive)
        patterns = try c.decodeIfPresent([DrillingPattern].self, forKey: .patterns)
        featureOrder = try c.decodeIfPresent([FeatureStep].self, forKey: .featureOrder)
        shopNumber = try c.decodeIfPresent(Int.self, forKey: .shopNumber)
        toolAssignments = try c.decodeIfPresent([String:UUID].self, forKey: .toolAssignments)
        shop = try c.decodeIfPresent(PartShopData.self,forKey:.shop)
        edges = try c.decodeIfPresent([EdgeProfile].self, forKey: .edges)
    }

    var rotMatrix: simd_double3x3 {
        let (a, b, c) = (rot.x * .pi / 180, rot.y * .pi / 180, rot.z * .pi / 180)
        let rx = simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cos(a), sin(a)), SIMD3(0, -sin(a), cos(a))))
        let ry = simd_double3x3(columns: (SIMD3(cos(b), 0, -sin(b)), SIMD3(0, 1, 0), SIMD3(sin(b), 0, cos(b))))
        let rz = simd_double3x3(columns: (SIMD3(cos(c), sin(c), 0), SIMD3(-sin(c), cos(c), 0), SIMD3(0, 0, 1)))
        return rz * ry * rx
    }

    /// Board-local point (min corner = 0) to world.
    func toWorld(_ local: SIMD3<Double>) -> SIMD3<Double> {
        isRotated ? center + rotMatrix * (local - size / 2) : origin + local
    }

    func dirToWorld(_ d: SIMD3<Double>) -> SIMD3<Double> { isRotated ? rotMatrix * d : d }

    /// World-space bounds including rotation (and tenons).
    var bounds: (lo: SIMD3<Double>, hi: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        var l0 = SIMD3<Double>.zero, h0 = size
        for c in cuts where c.additive && c.suppressed != true { l0 = pointwiseMin(l0, c.lo); h0 = pointwiseMax(h0, c.hi) }
        for i in 0..<8 {
            let pt = SIMD3(i & 1 == 0 ? l0.x : h0.x, i & 2 == 0 ? l0.y : h0.y, i & 4 == 0 ? l0.z : h0.z)
            let w = toWorld(pt)
            lo = pointwiseMin(lo, w); hi = pointwiseMax(hi, w)
        }
        return (lo, hi)
    }

    /// Clip planes (point, outward normal) in board-local space; material is kept where n·(x−p) ≤ 0.
    var trimPlanes: [(p: SIMD3<Double>, n: SIMD3<Double>)] {
        trims.filter { $0.suppressed != true }.map { t in
            let a = t.axis
            let across = [(a + 1) % 3, (a + 2) % 3].first { $0 != t.run }!
            var n0 = SIMD3<Double>.zero, p = SIMD3<Double>.zero, e = SIMD3<Double>.zero
            n0[a] = t.positive ? 1 : -1
            e[across] = t.farEdge ? -1 : 1
            p[a] = t.positive ? size[a] : 0
            p[across] = t.farEdge ? size[across] : 0
            let th = t.angle * .pi / 180
            return (p, n0 * cos(th) + e * sin(th))
        }
    }

    /// Clip planes from chamfers, roundovers and arches.
    var edgePlanes: [(p: SIMD3<Double>, n: SIMD3<Double>)] {
        var out: [(p: SIMD3<Double>, n: SIMD3<Double>)] = []
        for e in edges ?? [] {
            func unit(_ axis: Int, _ pos: Bool) -> SIMD3<Double> { var v = SIMD3<Double>.zero; v[axis] = pos ? 1 : -1; return v }
            switch e.kind {
            case .chamfer, .roundover:
                guard e.axis1 != e.axis2 else { continue }
                let e1 = unit(e.axis1, e.pos1), e2 = unit(e.axis2, e.pos2)
                var corner = SIMD3<Double>.zero
                for (ax, pos) in [(e.axis1, e.pos1), (e.axis2, e.pos2)] { corner[ax] = pos ? size[ax] : 0 }
                corner[3 - e.axis1 - e.axis2] = size[3 - e.axis1 - e.axis2] / 2
                if e.kind == .chamfer {
                    out.append((corner - e1 * e.size, simdNormalize(e1 + e2)))
                } else {
                    let c = corner - (e1 + e2) * e.size
                    let n = e.size > 1 ? 8 : 6
                    for k in 0..<n {
                        let phi = (Double(k) + 0.5) * (.pi / 2) / Double(n)
                        let nn = e1 * cos(phi) + e2 * sin(phi)
                        out.append((c + nn * e.size, nn))
                    }
                }
            case .arch:
                let a = e.axis1, r = e.axis2
                guard a != r else { continue }
                let w = size[r], h = min(e.size, w / 2)
                guard h > 1e-6 else { continue }
                let radius = (h * h + (w / 2) * (w / 2)) / (2 * h)
                var ea = SIMD3<Double>.zero, er = SIMD3<Double>.zero
                ea[a] = e.pos1 ? 1 : -1; er[r] = 1
                var c = SIMD3<Double>.zero
                c[r] = w / 2
                c[a] = (e.pos1 ? size[a] : 0) - ea[a] * radius
                c[3 - a - r] = size[3 - a - r] / 2
                let phiMax = asin(min(1, (w / 2) / radius))
                let n = 16
                for k in 0..<n {
                    let phi = -phiMax + (Double(k) + 0.5) * 2 * phiMax / Double(n)
                    let nn = ea * cos(phi) + er * sin(phi)
                    out.append((c + nn * radius, nn))
                }
            }
        }
        return out
    }
    var hasEdgeProfiles: Bool { !(edges ?? []).isEmpty }
    /// Miters/bevels plus edge profiles: everything that clips the outside of the blank.
    var clipPlanes: [(p: SIMD3<Double>, n: SIMD3<Double>)] { trimPlanes + edgePlanes }

    mutating func adjustJoinery(from old: Part) {
        if resizeJoinery == true {
            for i in (operations ?? []).indices {
                let op = operations![i]
                if op.sketch != nil { continue }
                operations![i].depth *= size[op.axis] / old.size[op.axis]
                operations![i].contour = op.contour.map { $0 * SIMD2(size[op.u] / old.size[op.u], size[op.v] / old.size[op.v]) }
                operations![i].islands = op.islands?.map { $0.map { $0 * SIMD2(size[op.u]/old.size[op.u],size[op.v]/old.size[op.v]) } }
            }
        }
        for j in cuts.indices {
            for axis in 0..<3 where size[axis] != old.size[axis] {
                if resizeJoinery == true {
                    cuts[j].lo[axis] *= size[axis] / old.size[axis]
                    cuts[j].hi[axis] *= size[axis] / old.size[axis]
                    if cuts[j].planes != nil { for k in cuts[j].planes!.indices { cuts[j].planes![k].p[axis] *= size[axis] / old.size[axis] } }
                } else if cuts[j].faceAxis == axis && cuts[j].facePositive == true {
                    let delta = size[axis] - old.size[axis]
                    cuts[j].lo[axis] += delta; cuts[j].hi[axis] += delta
                    if cuts[j].planes != nil { for k in cuts[j].planes!.indices { cuts[j].planes![k].p[axis] += delta } }
                }
            }
        }
    }

    /// Rotate the local coordinate system, preserving joinery and angled planes.
    func rotated90(axis k: Int) -> Part {
        var q = self
        let a = (k + 1) % 3, b = (k + 2) % 3
        let sa = size[a], sb = size[b]
        q.size[a] = sb; q.size[b] = sa
        q.origin = center - q.size / 2
        func remap(_ i: Int) -> Int { i == a ? b : (i == b ? a : i) }
        q.bindings = bindings?.map { binding in var n = binding; if n.target == .size { n.axis = remap(binding.axis) }; return n }
        q.thicknessAxis = remap(materialAxes.t)
        if materialAxes.t == b { q.cncTopPositive = !(cncTopPositive ?? true) }
        q.grainDirection = remap(materialAxes.l)
        q.profile = profile?.rotated90(axis: k)
        q.mesh = mesh.map { mesh in MeshSolid(faces: mesh.faces.map { $0.map { pt in
            var r = pt; r[a] = 1 - pt[b]; r[b] = pt[a]; return r
        } }) }
        q.patterns = patterns?.map { $0.rotated90(axis:k,part:self) }
        q.operations = operations?.map { op in
            var n = op
            n.axis = remap(op.axis)
            if op.axis == b { n.positive.toggle() }
            if let stretch = op.bottomStretch { n.bottomStretch = remap(op.u) == n.u ? stretch : SIMD2(stretch.y, stretch.x) }
            if var sketch = op.sketch {
                func point(_ uv: SIMD2<Double>) -> SIMD2<Double> {
                    var p = SIMD3<Double>.zero;p[op.u] = uv.x*size[op.u];p[op.v] = uv.y*size[op.v]
                    var r = p;r[a] = sb-p[b];r[b] = p[a]
                    return SIMD2(r[n.u]/q.size[n.u],r[n.v]/q.size[n.v])
                }
                let origin = point(.zero),u = point(SIMD2(1,0))-origin,v = point(SIMD2(0,1))-origin
                sketch.orientation = sketch.orientation.followed(by:SketchOrientation(x:SIMD2(u.x,v.x),y:SIMD2(u.y,v.y),offset:origin))
                n.sketch = sketch
            }
            n.contour = op.contour.map { pt in
                var p = SIMD3<Double>.zero; p[op.u] = pt.x; p[op.v] = pt.y
                var r = p; r[a] = sb - p[b]; r[b] = p[a]
                return SIMD2(r[n.u], r[n.v])
            }
            n.islands = op.islands?.map { hole in hole.map { pt in var p = SIMD3<Double>.zero;p[op.u] = pt.x;p[op.v] = pt.y;var r = p;r[a] = sb-p[b];r[b] = p[a];return SIMD2(r[n.u],r[n.v]) } }
            return n
        }
        q.cuts = cuts.map { c in
            var n = c
            n.lo[a] = sb - c.hi[b]; n.hi[a] = sb - c.lo[b]
            n.lo[b] = c.lo[a]; n.hi[b] = c.hi[a]
            n.faceAxis = c.faceAxis.map(remap)
            n.runAxis = c.runAxis.map(remap)
            if c.faceAxis == b, let positive = c.facePositive { n.facePositive = !positive }
            let oldNormal = c.faceAxis ?? materialAxes.t, newNormal = n.faceAxis ?? q.materialAxes.t
            let oldU = (oldNormal + 1) % 3, oldV = (oldNormal + 2) % 3, newU = (newNormal + 1) % 3, newV = (newNormal + 2) % 3
            let run = c.runAxis ?? (0..<3).first { $0 != oldNormal }!
            let across = (0..<3).first { $0 != oldNormal && $0 != run }!
            if across == b { n.offsetFromFar = !(c.offsetFromFar ?? false) }
            if var relief = c.relief {
                var corners = Array(repeating: false, count: 4)
                for i in 0..<4 {
                    var pt = c.lo
                    pt[oldU] = i == 0 || i == 3 ? c.lo[oldU] : c.hi[oldU]
                    pt[oldV] = i < 2 ? c.lo[oldV] : c.hi[oldV]
                    var r = pt; r[a] = sb - pt[b]; r[b] = pt[a]
                    let right = abs(r[newU] - n.hi[newU]) < 1e-6, top = abs(r[newV] - n.hi[newV]) < 1e-6
                    let j = top ? (right ? 2 : 3) : (right ? 1 : 0); corners[j] = relief.corners[i]
                }
                relief.corners = corners
                if remap(oldU) != newU {
                    if relief.style == .tboneX { relief.style = .tboneY } else if relief.style == .tboneY { relief.style = .tboneX }
                }
                n.relief = relief
            }
            n.planes = c.planes?.map { pl in
                func m(_ v: SIMD3<Double>, point: Bool) -> SIMD3<Double> {
                    var r = v
                    r[a] = point ? sb - v[b] : -v[b]
                    r[b] = v[a]
                    return r
                }
                return Plane(p: m(pl.p, point: true), n: m(pl.n, point: false))
            }
            return n
        }
        q.edges = edges?.map { e in
            var n = e
            n.axis1 = remap(e.axis1); n.axis2 = remap(e.axis2)
            if e.axis1 == b { n.pos1.toggle() }
            if e.axis2 == b, e.kind != .arch { n.pos2.toggle() }
            return n
        }
        q.trims = trims.map { t in
            var n = t
            n.axis = remap(t.axis); n.run = remap(t.run)
            if t.axis == b { n.positive.toggle() }
            let across = (0..<3).first { $0 != t.axis && $0 != t.run }!
            if across == b { n.farEdge.toggle() }
            return n
        }
        return q
    }
}

struct FaceRef: Equatable {
    var part: UUID
    var axis: Int
    var positive: Bool
    static let axisNames = ["X", "Y", "Z"]
    var label: String {
        let side = positive ? "+" : "-"
        let nice = axis == 1 ? (positive ? " (top)" : " (bottom)") : ""
        return side + FaceRef.axisNames[axis] + nice
    }
}

enum Tool: String, CaseIterable, Identifiable {
    case select, move, pushPull, rectangle, tape
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return "Select"
        case .move: return "Move"
        case .pushPull: return "Push/Pull"
        case .rectangle: return "Rectangle"
        case .tape: return "Tape Measure"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .pushPull: return "square.stack.3d.up"
        case .rectangle: return "rectangle.dashed"
        case .tape: return "ruler"
        }
    }
    var key: String {
        switch self {
        case .select: return "Space"
        case .move: return "M"
        case .pushPull: return "P"
        case .rectangle: return "R"
        case .tape: return "T"
        }
    }
    var hint: String {
        switch self {
        case .select: return "Click to select · Right-click for actions · F fits selection · H hides · Option-drag orbits."
        case .move: return "Drag a board or axis handle. Shift = vertical. Arrows lock X/Z/Y; ↓ frees. Type distance + Return; Escape cancels."
        case .pushPull: return "Drag a face to lengthen, widen or thicken a board."
        case .rectangle: return "Drag on the ground or a face to draw a new board (thickness set in the inspector)."
        case .tape: return "Click two points to measure."
        }
    }
}

// MARK: - Document

struct DimensionLink: Codable, Equatable, Identifiable {
    var id = UUID()
    var source: UUID
    var sourceAxis: Int
    var target: UUID
    var targetAxis: Int
    var offset: Double = 0
}

struct Project: Codable, Equatable {
    var version = 6
    var parts: [Part] = []
    var metric = false
    var snap = 1.0 / 16
    var species = Species.oak
    var stockName = Stock.all[2].name
    var stockLength = 48.0
    var rectThickness = 0.75
    var sheetLength = 96.0
    var sheetWidth = 48.0
    var nestGap = 0.5
    var links: [DimensionLink] = []
    var studio: StudioState? = nil
}

private struct UndoRecord {
    var project: Project
    var selection: UUID?
    var selectedIDs: Set<UUID>
    var face: FaceRef?
}

final class Document: ObservableObject {
    let workspaceStore: WorkspacePreferencesStore?
    @Published var showEditableDimensions = true
    @Published var partFilter = "All"
    @Published var partSearch = ""
    @Published var dimensionRequest: DimensionRequest?
    @Published var faceSketchRequest: FaceSketchRequest?
    @Published var faceSketchEditorActive = false
    @Published var showProjectPreset = false
    @Published var showMachiningRecipes = false
    @Published var cncPartIDs: Set<UUID>?
    @Published var showPartsSidebar = true
    @Published var showInspector = true
    @Published var inspectorPage = InspectorPage.part
    @Published var renamePartID: UUID?
    @Published var showCommandPalette = false
    @Published var makeArea = MakeArea.fabrication
    @Published var shopTab = 0 { didSet { makeArea = .shop } }
    @Published var hardwareTemplates: [HardwareTemplate] = []
    let hardwareTemplateStore: HardwareTemplateStore
    @Published var focusPartSearch = UUID()
    @Published var parts: [Part] = []
    @Published var parameterPreview: Project?
    @Published var previewAffected: Set<UUID> = []
    @Published var previewConflicts: Set<UUID> = []
    @Published var selectedFeature: FeatureRef?
    @Published var showFeatureEditor = false
    @Published var historyInspection: HistoryInspection?
    @Published var showReviewHighlights = false
    @Published var setupProfiles: [CNCSetupProfile] = []
    let setupProfileStore: SetupProfileStore
    @Published var studio = StudioState()
    @Published var workshopTab = 0
    @Published var showWorkshop = false
    @Published var showDesign = false
    @Published var lastMeasurement: [SIMD3<Double>] = []
    @Published var selectedSurface: Int? = nil
    @Published var selection: UUID? {
        didSet {
            if let selection, !selectedIDs.contains(selection) { selectedIDs = [selection] }
            if selection == nil { selectedIDs = []; isolateSelection = false }
        }
    }
    @Published var selectedIDs: Set<UUID> = []
    @Published var selectedFace: FaceRef?
    @Published var tool: Tool = .select { didSet { status = tool.hint } }
    @Published var snap: Double = 1.0 / 16
    @Published var metric = false {
        didSet { if oldValue != metric { snap = metric ? 1 / 25.4 : 1 / 16 } }
    }
    @Published var species: Species = .oak
    @Published var stock: Stock = Stock.all[2] {
        didSet { stockLength = stock.length; rectThickness = stock.thickness }
    }
    @Published var stockLength: Double = 48
    @Published var rectThickness: Double = 0.75
    @Published var status = Tool.select.hint
    @Published var axisLock: Int?
    @Published var showCutList = false
    @Published var fabricationTab = 0 { didSet { makeArea = .fabrication } }
    @Published var cncSetup = CNCSetup.top
    @Published var fileName = "Untitled"
    @Published var sheetLength: Double = 96
    @Published var sheetWidth: Double = 48
    @Published var nestGap: Double = 0.5
    @Published var links: [DimensionLink] = []
    @Published var isolateSelection = false
    @Published var editRevision = 0
    @Published var savedProject = Project()
    @Published private var recoveredUnsaved = false
    @Published var exactDistance = ""
    @Published var activeDrag = false
    var applyDistance: ((Double) -> Void)?
    var cancelDrag: (() -> Void)?
    var finishDrag: (() -> Void)?

    var historyOrigin: DesignSnapshot?
    private var undoStack: [UndoRecord] = []
    private var redoStack: [UndoRecord] = []
    private var fileURL: URL?
    private var diskFingerprint: String?
    private var checkpointRedo: [UndoRecord] = []
    private var counter = 0
    private var recoveryTimer: Timer?
    private var lastRecovery: Project?
    private let recoveryLocation: URL?

    init(startRecoveryTimer: Bool = true, recoveryLocation: URL? = nil, setupStoreURL: URL? = nil, workspaceStore: WorkspacePreferencesStore? = nil,hardwareStoreURL: URL? = nil) {
        self.workspaceStore = workspaceStore ?? (startRecoveryTimer ? WorkspacePreferencesStore() : nil)
        self.hardwareTemplateStore = HardwareTemplateStore(url:hardwareStoreURL)
        self.hardwareTemplates = self.hardwareTemplateStore.load()
        self.recoveryLocation = recoveryLocation
        self.setupProfileStore = SetupProfileStore(url: setupStoreURL)
        self.setupProfiles = self.setupProfileStore.load()
        if let store = self.workspaceStore {
            let p = store.load()
            showPartsSidebar = p.partsVisible;showInspector = p.inspectorVisible;showEditableDimensions = p.dimensionsVisible
            partFilter = ["All","Parts","Hardware"].contains(p.partFilter) ? p.partFilter : "All";partSearch = p.partSearch;metric = p.metric
            if let profile = setupProfiles.first(where: { $0.id == p.setupID }) ?? p.activeSetup,(try? profile.validate()) != nil {
                studio.setupProfile = profile;studio.registration = profile.registration
                sheetLength = profile.sheetLength;sheetWidth = profile.sheetWidth;nestGap = profile.gap
            }
        }
        savedProject = project
        if startRecoveryTimer {
            recoveryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.autosaveRecovery() }
        }
    }
    deinit { recoveryTimer?.invalidate() }

    var project: Project {
        Project(parts: parts, metric: metric, snap: snap, species: species, stockName: stock.name,
                stockLength: stockLength, rectThickness: rectThickness, sheetLength: sheetLength,
                sheetWidth: sheetWidth, nestGap: nestGap, links: links, studio: studio)
    }
    var isDirty: Bool {
        var current = project, saved = savedProject
        current.studio?.history = nil; saved.studio?.history = nil
        current.studio?.nextShopNumber = nil; saved.studio?.nextShopNumber = nil
        return recoveredUnsaved || current != saved
    }
    func restore(_ original: Project) {
        let p = ShopIdentity.numbered(original)
        parameterPreview = nil; previewAffected = []; previewConflicts = []; historyInspection = nil; selectedFeature = nil
        studio = p.studio ?? StudioState()
        parts = p.parts; metric = p.metric; snap = p.snap; species = p.species
        stock = Stock.all.first { $0.name == p.stockName } ?? Stock.all[2]
        stockLength = p.stockLength; rectThickness = p.rectThickness
        sheetLength = p.sheetLength; sheetWidth = p.sheetWidth; nestGap = p.nestGap; links = p.links
        fixSelection()
    }
    func part(_ id: UUID) -> Part? { parts.first { $0.id == id } }
    var selectedPart: Part? { selection.flatMap(part) }
    func fmt(_ v: Double) -> String { Units.format(v, metric: metric) }
    func isVisible(_ p: Part) -> Bool { p.hidden != true && (!isolateSelection || selectedIDs.contains(p.id)) }
    func select(_ id: UUID, extending: Bool = false) {
        finishDrag?()
        if selectedFeature?.part != id { selectedFeature = nil }
        if extending {
            var ids = selectedIDs
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            selection = ids.contains(id) ? id : ids.first
            selectedIDs = ids
        } else { selection = id; selectedIDs = [id] }
        selectedFace = nil; selectedSurface = nil
    }

    private var undoRecord: UndoRecord { UndoRecord(project: project, selection: selection, selectedIDs: selectedIDs, face: selectedFace) }
    private func restoreUndo(_ record: UndoRecord) {
        restore(record.project)
        selection = record.selection; selectedIDs = record.selectedIDs; selectedFace = record.face; selectedSurface = nil
        fixSelection()
    }
    func checkpoint() {
        finishDrag?()
        historyOrigin = designSnapshot
        checkpointRedo = redoStack
        undoStack.append(undoRecord)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    func discardCheckpointIfUnchanged() {
        if undoStack.last?.project == project { undoStack.removeLast(); redoStack = checkpointRedo }
        else { recordHistory() }
        checkpointRedo = []
    }
    func cancelCheckpoint() {
        if let previous = undoStack.popLast() { restoreUndo(previous); redoStack = checkpointRedo }
        checkpointRedo = []
    }
    func update(_ id: UUID, adjustJoinery: Bool = true, _ f: (inout Part) -> Void) {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return }
        let old = parts[i]
        var next = old
        f(&next)
        if let message = ModelValidation.axes(next) { status = message; return }
        if adjustJoinery, next.size != old.size, next.cuts == old.cuts {
            next.adjustJoinery(from: old)
        }
        next.bindings?.removeAll { binding in
            guard let feature = binding.feature else { return false }
            return !next.cuts.contains(where: { $0.id == feature }) && !(next.operations ?? []).contains(where: { $0.id == feature })
        }
        _ = applyPartChanges([next])
    }
    /// Stage all moved/edited parts together, then regenerate once. A rejected edit leaves the assembly intact.
    @discardableResult func applyPartChanges(_ replacements: [Part]) -> Bool {
        let original = parts
        do {
            guard Set(replacements.map(\.id)).count == replacements.count else { throw ModelValidation.Failure(message:"An edit contains the same part twice.") }
            for next in replacements {
                guard let i = parts.firstIndex(where: { $0.id == next.id }) else { throw ModelValidation.Failure(message:"The edited part no longer exists.") }
                parts[i] = next
                if let component = next.component {
                    for j in parts.indices where j != i && parts[j].component == component && !replacements.contains(where: { $0.id == parts[j].id }) {
                        let instance = parts[j]
                        parts[j] = next
                        parts[j].id = instance.id; parts[j].shopNumber = instance.shopNumber; parts[j].name = instance.name; parts[j].origin = instance.origin
                        parts[j].rot = instance.rot; parts[j].bindings = instance.bindings; parts[j].group = instance.group; parts[j].hidden = instance.hidden
                    }
                }
            }
            try Regeneration.rebuild(parts:&parts,links:links,studio:studio)
            try ModelValidation.validate(project)
            if let face = selectedFace,let before = original.first(where: { $0.id == face.part }),let after = part(face.part),before.profile != after.profile || before.mesh != after.mesh { selectedFace = nil }
            if parts != original { selectedSurface = nil; editRevision += 1 }
            fixSelection()
            return true
        } catch { parts = original; status = error.localizedDescription; return false }
    }
    @discardableResult func propagateLinks(from source: UUID) -> Bool {
        do { try Regeneration.rebuild(parts:&parts,links:links,studio:studio); return true }
        catch { status = error.localizedDescription; return false }
    }
    func addLink(_ link: DimensionLink) {
        guard link.source != link.target, part(link.source) != nil, part(link.target) != nil,
              (0..<3).contains(link.sourceAxis), (0..<3).contains(link.targetAxis), link.offset.isFinite else { return }
        if let source = part(link.source), source.size[link.sourceAxis] + link.offset < 1 / 32 {
            status = "The relationship would produce a size below 1/32 inch."; return
        }
        var reachable: Set<UUID> = [link.target]
        for _ in 0...links.count {
            for l in links where reachable.contains(l.source) { reachable.insert(l.target) }
        }
        guard !reachable.contains(link.source) else { status = "That relationship would create a cycle."; return }
        checkpoint()
        links.removeAll { $0.target == link.target && $0.targetAxis == link.targetAxis }
        links.append(link)
        if !propagateLinks(from: link.source) { cancelCheckpoint(); status = "Invalid linked dimensions." }
        else { recordHistory("Link dimensions") }
    }
    func edit(_ id: UUID, _ f: (inout Part) -> Void) {
        checkpoint(); update(id, f); discardCheckpointIfUnchanged()
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    func undo() {
        finishDrag?()
        guard let prev = undoStack.popLast() else { return }
        let history = studio.history
        redoStack.append(undoRecord); restoreUndo(prev); studio.history = history; recordHistory("Undo")
    }
    func redo() {
        finishDrag?()
        guard let next = redoStack.popLast() else { return }
        let history = studio.history
        undoStack.append(undoRecord); restoreUndo(next); studio.history = history; recordHistory("Redo")
    }
    func fixSelection() {
        if let feature = selectedFeature, let p = part(feature.part), !p.featureSteps.contains(FeatureStep(kind:feature.kind,feature:feature.feature)) { selectedFeature = nil }
        if let feature = selectedFeature, part(feature.part) == nil { selectedFeature = nil }
        let valid = Set(parts.map(\.id))
        let ids = selectedIDs.intersection(valid)
        if let s = selection, !valid.contains(s) { selection = ids.first; selectedFace = nil }
        selectedIDs = ids
    }
    func nextName(_ base: String) -> String {
        repeat { counter += 1 } while parts.contains { $0.name == "\(base) \(counter)" }
        return "\(base) \(counter)"
    }
    func add(_ p: Part, select: Bool = true) {
        if let error = ModelValidation.part(p) { status = error; return }
        guard !parts.contains(where: { $0.id == p.id }) else { status = "This part is already in the project. Use Duplicate to make a copy."; return }
        guard !p.cuts.contains(where: { $0.mateID != nil }) else { status = "Add the board first, then create linked joinery, or insert the part from the component library."; return }
        if transaction({
            parts.append(p)
            if select { selection = p.id; selectedIDs = [p.id]; selectedFace = nil }
        }) { recordHistory("Add " + p.name) }
    }
    func addStock() {
        let sp: Species = stock.hardware ?? (stock.sheet && !species.isSheet ? .plywood : species)
        let z = (parts.map { $0.bounds.hi.z }.max() ?? -2) + 2
        var p = Part(name: nextName(stock.name), origin: SIMD3(0, 0, z),
                     size: SIMD3(stock.hardware != nil ? stock.length : stockLength, stock.thickness, stock.width), species: sp)
        p.thicknessAxis = 1; p.grainDirection = 0
        if stock.hardware != nil { p.hardware = true }
        add(p)
    }
    func deleteSelected() {
        guard !selectedIDs.isEmpty else { return }
        let ids = selectedIDs
        if transaction({
            parts.removeAll { ids.contains($0.id) }
            links.removeAll { ids.contains($0.source) || ids.contains($0.target) }
            studio.relations?.removeAll { ids.contains($0.source) || ids.contains($0.target) }
            studio.matingJoints?.removeAll { ids.contains($0.shelf) || ids.contains($0.receiver) }
            selection = nil; selectedFace = nil
        }) { recordHistory("Delete parts") }
    }
    func duplicateSelected() {
        let originals = parts.filter { selectedIDs.contains($0.id) }
        guard !originals.isEmpty else { return }
        if transaction({
            var ids: Set<UUID> = []
            var copies: [UUID: UUID] = [:]
            for var p in originals {
                let originalID = p.id
                p.id = UUID(); copies[originalID] = p.id; p.name += " copy"; p.origin += SIMD3(2, 0, 2)
                p.bindings?.removeAll { [.position,.rotation].contains($0.target) }
                // Feature identifiers are scoped to a part and stay stable for expressions and component instances.
                if let group = p.group { p.group = group + " copy" }
                parts.append(p); ids.insert(p.id)
            }
            let copiedLinks = links.compactMap { link -> DimensionLink? in
                guard let target = copies[link.target] else { return nil }
                return DimensionLink(source: copies[link.source] ?? link.source, sourceAxis: link.sourceAxis,
                                     target: target, targetAxis: link.targetAxis, offset: link.offset)
            }
            links += copiedLinks
            replicateMates(copies)
            selection = ids.first; selectedIDs = ids; selectedFace = nil
        }) { recordHistory("Duplicate parts") }
    }
    func rotateSelected(axis: Int) {
        guard (0..<3).contains(axis) else { status = "Choose a valid rotation axis."; return }
        guard let p = selectedPart, !p.isRotated else { return }
        let success = transaction {
            let a = (axis + 1) % 3, b = (axis + 2) % 3
            func remap(_ value: Int) -> Int { value == a ? b : (value == b ? a : value) }
            for i in links.indices {
                if links[i].source == p.id { links[i].sourceAxis = remap(links[i].sourceAxis) }
                if links[i].target == p.id { links[i].targetAxis = remap(links[i].targetAxis) }
            }
            for i in (studio.matingJoints ?? []).indices where studio.matingJoints![i].receiver == p.id {
                if studio.matingJoints![i].axis == b { studio.matingJoints![i].positive.toggle() }
                studio.matingJoints![i].axis = remap(studio.matingJoints![i].axis)
            }
            if let i = parts.firstIndex(where: { $0.id == p.id }) { parts[i] = p.rotated90(axis: axis) }
            if !propagateLinks(from: p.id) { throw ModelValidation.Failure(message: "The rotation conflicts with a driven dimension. Unlink it before rotating.") }
        }
        if success { selectedFace = nil; status = "Rotated 90°; machining and parameters preserved."; recordHistory("Rotate " + p.name) }
    }
    func setGroup(_ name: String) {
        checkpoint()
        for i in parts.indices where selectedIDs.contains(parts[i].id) { parts[i].group = name.isEmpty ? nil : name }
        recordHistory("Assign assembly")
    }
    func alignSelected(axis: Int, maximum: Bool = false) {
        guard let anchor = selectedPart, selectedIDs.count > 1 else { return }
        transaction {
            let edge = maximum ? anchor.bounds.hi[axis] : anchor.bounds.lo[axis]
            for i in parts.indices where selectedIDs.contains(parts[i].id) && parts[i].id != anchor.id {
                let b = parts[i].bounds
                parts[i].origin[axis] += edge - (maximum ? b.hi[axis] : b.lo[axis])
            }
        }
    }

    // MARK: Files and recovery
    private static let fileType = UTType(exportedAs: "com.local.woodshop.project", conformingTo: .json)
    struct Recovery: Codable { var project: Project; var originalURL: URL?; var name: String; var originalFingerprint: String? = nil }
    private var recoveryURL: URL {
        if let recoveryLocation { return recoveryLocation }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WoodShop")
        return dir.appendingPathComponent("Recovery.json")
    }
    func autosaveRecovery() {
        guard isDirty else { if lastRecovery != nil { clearRecovery() }; return }
        guard lastRecovery != project else { return }
        do {
            try ModelValidation.validate(project)
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Recovery(project:project,originalURL:fileURL,name:fileName,originalFingerprint:diskFingerprint))
            try ProjectStorage.write(data,to:recoveryURL) { old in
                let recovery = try JSONDecoder().decode(Recovery.self,from:old)
                try ModelValidation.validate(recovery.project)
            }
            lastRecovery = project
        } catch { status = "Recovery save failed: \(error.localizedDescription)" }
    }
    func recoverIfAvailable() {
        guard let r = try? ProjectStorage.recovery(at:recoveryURL) else { return }
        let alert = NSAlert()
        alert.messageText = "Recover unsaved work?"
        alert.informativeText = "An unsaved version of \(r.name) is available."
        alert.addButton(withTitle: "Recover"); alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertFirstButtonReturn {
            do { try restoreRecovery(r) } catch { status = "Recovery failed: " + error.localizedDescription }
        } else { clearRecovery() }
    }
    var activeProjectURL: URL? { fileURL }
    var recoveryFileURL: URL { recoveryURL }
    func restoreRecovery(_ recovery: Recovery) throws {
        try ModelValidation.validate(recovery.project)
        restore(recovery.project); fileName = recovery.name; fileURL = recovery.originalURL
        // Legacy recovery files have no baseline; force Save As rather than overwrite an unknown disk version.
        diskFingerprint = recovery.originalFingerprint ?? (recovery.originalURL == nil ? nil : "unknown-recovery-baseline")
        savedProject = Project(); recoveredUnsaved = true; undoStack = []; redoStack = []
    }
    private func clearRecovery() {
        for url in [recoveryURL]+ProjectStorage.backupURLs(recoveryURL) { try? FileManager.default.removeItem(at:url) }
        lastRecovery = nil
    }
    func confirmDiscard() -> Bool {
        finishDrag?()
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(fileName)?"
        alert.informativeText = "Your changes will be lost if you discard them."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: clearRecovery(); savedProject = project; recoveredUnsaved = false; return true
        default: return false
        }
    }
    func newDocument() {
        guard confirmDiscard() else { return }
        restore(Project()); selection = nil; selectedFace = nil;cncPartIDs = nil
        fileURL = nil; diskFingerprint = nil; fileName = "Untitled"; savedProject = project; recoveredUnsaved = false
        undoStack = []; redoStack = []; clearRecovery()
    }
    @discardableResult func save(asNew: Bool = false) -> Bool {
        finishDrag?()
        var url = fileURL
        if url == nil || asNew {
            let panel = NSSavePanel(); panel.allowedContentTypes = [Document.fileType]
            panel.nameFieldStringValue = fileName + ".wood"
            guard panel.runModal() == .OK, let u = panel.url else { return false }
            url = u
        }
        guard let url else { return false }
        do {
            try writeProject(to: url)
            return true
        } catch { status = "Save failed: \(error.localizedDescription)"; return false }
    }
    func writeProject(to url: URL) throws {
        finishDrag?()
        try ModelValidation.validate(project)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(project)
        if fileURL?.standardizedFileURL == url.standardizedFileURL,let baseline = diskFingerprint {
            guard let current = try? Data(contentsOf:url),ProjectStorage.fingerprint(current) == baseline else {
                throw ModelValidation.Failure(message:"This project changed on disk since it was opened or saved. Use Save As to preserve your work in a separate file, or reopen the changed project.")
            }
        }
        try ProjectStorage.write(data,to:url) { _ = try Self.decodeProject($0) }
        diskFingerprint = ProjectStorage.fingerprint(data)
        fileURL = url; fileName = url.deletingPathExtension().lastPathComponent
        savedProject = project; recoveredUnsaved = false; clearRecovery()
        Recents.add(url)
        status = "Saved \(url.lastPathComponent)"
    }
    var canRestorePreviousSave: Bool { fileURL.map { FileManager.default.fileExists(atPath:ProjectStorage.previousURL($0).path) } ?? false }
    func restorePreviousSave() {
        guard let fileURL else { status = "Save the project first to create a previous version."; return }
        do {
            let previous = try Self.decodeProject(Data(contentsOf:ProjectStorage.previousURL(fileURL)))
            if transaction({ restore(previous) }) { status = "Restored the previous saved version. Undo returns to your current design; Save keeps the restored version." }
        } catch { status = "Previous version could not be restored: " + error.localizedDescription }
    }
    static func decodeProject(_ data: Data) throws -> Project {
        let decoder = JSONDecoder()
        let p: Project
        if let legacy = try? decoder.decode([Part].self, from: data) { p = Project(parts: legacy) }
        else { p = try decoder.decode(Project.self, from: data) }
        try ModelValidation.validate(p)
        return p
    }
    func open() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [Document.fileType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }
    func open(url: URL) {
        do {
            let data = try Data(contentsOf:url)
            let loaded = try Self.decodeProject(data)
            guard confirmDiscard() else { return }
            restore(loaded); selection = nil; selectedFace = nil;cncPartIDs = nil
            fileURL = url; diskFingerprint = ProjectStorage.fingerprint(data); fileName = url.deletingPathExtension().lastPathComponent
            savedProject = project; recoveredUnsaved = false; undoStack = []; redoStack = []; clearRecovery()
            Recents.add(url)
            status = "Opened \(url.lastPathComponent)"
        } catch { status = "Open failed: \(error.localizedDescription)" }
    }
    func newGarageCabinetProject() {
        do {
            let layout = try GarageCabinets.project()
            guard confirmDiscard() else { return }
            restore(layout); fileURL = nil; diskFingerprint = nil; fileName = "Garage cabinets"
            savedProject = Project(); recoveredUnsaved = true; undoStack = []; redoStack = []; clearRecovery()
            recordHistory("Create garage cabinet layout")
            status = "Complete 12-foot garage layout. Use Views for the interior, drawer boxes, and front elevation; Parameters & History controls the dimensions."
        } catch { status = "Garage layout could not be created: " + error.localizedDescription }
    }
    // MARK: Example

    /// A small bookcase with dadoed shelves, to show off joinery.
    func insertExample() {
        checkpoint()
        let s = species
        let side = SIMD3<Double>(0.75, 36, 11.25)
        let shelfY: [Double] = [3, 17, 35.25]
        func dados(innerLocalX: ClosedRange<Double>) -> [Cut] {
            shelfY.map { y in
                Cut(kind: "Dado", lo: SIMD3(innerLocalX.lowerBound, y, 0),
                    hi: SIMD3(innerLocalX.upperBound, y + 0.75, side.z),
                    faceAxis: 0, facePositive: innerLocalX.lowerBound > 0, runAxis: 2)
            }
        }
        parts.append(Part(name: "Left Side", origin: SIMD3(0, 0, 0), size: side, species: s,
                          cuts: dados(innerLocalX: 0.5...0.75)))
        parts.append(Part(name: "Right Side", origin: SIMD3(30.75, 0, 0), size: side, species: s,
                          cuts: dados(innerLocalX: 0...0.25)))
        for (i, y) in shelfY.enumerated() {
            parts.append(Part(name: i == 2 ? "Top" : (i == 0 ? "Bottom" : "Shelf"),
                              origin: SIMD3(0.5, y, 0), size: SIMD3(30.5, 0.75, 11.25), species: s))
        }
        parts.append(Part(name: "Back", origin: SIMD3(0.75, 3.75, 11.25), size: SIMD3(30, 31.5, 0.25), species: .plywood))
        status = "Inserted example bookcase."
        recordHistory("Insert bookcase")
    }
}
