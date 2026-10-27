import Foundation
import simd

enum AssemblyAnchor: String,Codable,CaseIterable,Identifiable {
    case minimum = "Minimum edge",center = "Center",maximum = "Maximum edge"
    var id: String { rawValue }
    func value(_ box: (lo: SIMD3<Double>,hi: SIMD3<Double>),axis: Int) -> Double {
        switch self { case .minimum:return box.lo[axis];case .center:return (box.lo[axis]+box.hi[axis])/2;case .maximum:return box.hi[axis] }
    }
}
struct AssemblyRelation: Codable,Equatable,Identifiable {
    var id = UUID()
    var source: UUID
    var target: UUID
    var axis: Int
    var sourceAnchor = AssemblyAnchor.maximum
    var targetAnchor = AssemblyAnchor.minimum
    var offset = 0.0
    var expression: String? = nil
    var metricLiterals = false
}
enum AssemblyRelations {
    static func validateDrivers(parts: [Part],relations: [AssemblyRelation],joints: [MatingJoint]) throws {
        for relation in relations {
            guard let part = parts.first(where: { $0.id == relation.target }) else { continue }
            if (part.bindings ?? []).contains(where: { $0.target == .position && $0.axis == relation.axis }) {
                throw ModelValidation.Failure(message:part.name+": its position is already driven on this axis. Remove the position expression before adding an assembly relationship.")
            }
            if joints.contains(where: { !$0.suppressed && $0.autoSeat && $0.shelf == relation.target }) {
                throw ModelValidation.Failure(message:part.name+": automatic shelf seating already positions this part. Disable seating before adding an assembly relationship.")
            }
        }
    }
    static func rebuild(_ parts: inout [Part],relations: [AssemblyRelation],values: [String:Quantity]) throws {
        let ids = Set(parts.map(\.id));var destinations: Set<String> = []
        for r in relations {
            guard ids.contains(r.source),ids.contains(r.target),r.source != r.target,(0..<3).contains(r.axis),r.offset.isFinite,
                  destinations.insert(r.target.uuidString+String(r.axis)).inserted else { throw ModelValidation.Failure(message:"An assembly relationship has a missing part, duplicate driven axis, or invalid offset.") }
        }
        var pending = Set(relations.map(\.target))
        while !pending.isEmpty {
            let ready = pending.filter { target in !relations.contains { $0.target == target && pending.contains($0.source) } }
            guard !ready.isEmpty else { throw ModelValidation.Failure(message:"Assembly relationships contain a cycle. Remove one relationship or choose another reference part.") }
            for target in ready {
                guard let index = parts.firstIndex(where: { $0.id == target }) else { continue }
                for r in relations where r.target == target {
                    let source = parts.first { $0.id == r.source }!
                    let offset = try r.expression.map { try Parametric.evaluate(DesignBinding(target:.position,expression:$0,metricLiterals:r.metricLiterals),values:values) } ?? r.offset
                    let desired = r.sourceAnchor.value(source.bounds,axis:r.axis)+offset,current = r.targetAnchor.value(parts[index].bounds,axis:r.axis)
                    guard desired.isFinite else { throw ModelValidation.Failure(message:"The assembly relationship produced an invalid position.") }
                    parts[index].origin[r.axis] += desired-current
                }
            }
            pending.subtract(ready)
        }
    }
}

struct AssemblyIssue: Identifiable {
    var id: String
    var parts: [UUID]
    var severity: ReviewSeverity
    var message: String
}
enum AssemblyReview {
    static func volume(_ polygons: [Geo.Poly]) -> Double {
        abs(polygons.reduce(0) { total,p in
            guard p.pts.count>=3 else { return total }
            return total+(1..<(p.pts.count-1)).reduce(0) { $0+simd_dot(p.pts[0],simd_cross(p.pts[$1],p.pts[$1+1]))/6 }
        })
    }
    static func issues(_ project: Project,minimumClearance: Double = 1/16,cancelled: () -> Bool = {false}) -> [AssemblyIssue] {
        let parts = project.parts.filter { $0.hardware != true }.sorted { $0.bounds.lo.x<$1.bounds.lo.x }
        var result: [AssemblyIssue] = [],cache: [UUID:[Geo.Poly]] = [:]
        func polygons(_ p: Part) -> [Geo.Poly] { if let value = cache[p.id] { return value };let value = Geo.polys(for:p).map { Geo.Poly(pts:$0.pts.map(p.toWorld),n:p.dirToWorld($0.n)) };cache[p.id] = value;return value }
        for i in parts.indices {
            if cancelled() { return result }
            let a = parts[i],ab = a.bounds
            for j in (i+1)..<parts.count {
                let b = parts[j],bb = b.bounds
                if bb.lo.x>ab.hi.x+minimumClearance { break }
                let overlap = pointwiseMin(ab.hi,bb.hi)-pointwiseMax(ab.lo,bb.lo)
                let pair = [a.id,b.id],key = a.id.uuidString+b.id.uuidString
                if (0..<3).allSatisfy({overlap[$0]>1e-6}) {
                    let intersection = SolidCSG.intersection(polygons(a),polygons(b))
                    if volume(intersection)>1e-6 {
                        result.append(AssemblyIssue(id:key,parts:pair,severity:.error,message:ShopIdentity.label(a)+" "+a.name+" intersects "+ShopIdentity.label(b)+" "+b.name+". Inspect the mating faces or positions."))
                    }
                } else {
                    let separated = (0..<3).filter { overlap[$0]<(-1e-6) }
                    guard separated.count == 1,let axis = separated.first,-overlap[axis]<minimumClearance,
                          (0..<3).filter({$0 != axis}).allSatisfy({overlap[$0]>1e-6}),
                          !(project.studio?.matingJoints ?? []).contains(where: { !$0.suppressed && Set([$0.shelf,$0.receiver]) == Set(pair) }) else { continue }
                    result.append(AssemblyIssue(id:key,parts:pair,severity:.warning,message:ShopIdentity.label(a)+" / "+ShopIdentity.label(b)+": only "+Units.format(-overlap[axis],metric:project.metric)+" clearance along "+FaceRef.axisNames[axis]+". Check the intended fit."))
                }
            }
        }
        return result.sorted { $0.severity>$1.severity }
    }
    static func holeAlignment(_ parts: [Part],tolerance: Double = 0.01,metric: Bool = false) -> [AssemblyIssue] {
        guard parts.count == 2 else { return [] }
        let a = parts[0],b = parts[1]
        let aa = a.machiningOperations.filter { $0.kind == "Drill" && $0.suppressed != true },bb = b.machiningOperations.filter { $0.kind == "Drill" && $0.suppressed != true }
        return aa.compactMap { op in
            var p = SIMD3<Double>.zero;p[op.u] = op.openingBounds.center.x;p[op.v] = op.openingBounds.center.y;p[op.axis] = op.positive ? a.size[op.axis] : 0
            var normal = SIMD3<Double>.zero;normal[op.axis] = 1;normal = a.dirToWorld(normal)
            let origin = a.toWorld(p)
            let candidates = bb.compactMap { other -> Double? in
                var direction = SIMD3<Double>.zero;direction[other.axis] = 1;direction = b.dirToWorld(direction)
                guard abs(simd_dot(normal,direction))>0.9999 else { return nil }
                var q = SIMD3<Double>.zero;q[other.u] = other.openingBounds.center.x;q[other.v] = other.openingBounds.center.y;q[other.axis] = other.positive ? b.size[other.axis] : 0
                return simd_length(simd_cross(b.toWorld(q)-origin,normal))
            }
            guard let closest = candidates.min(),closest>tolerance else { return nil }
            return AssemblyIssue(id:op.id.uuidString,parts:[a.id,b.id],severity:.warning,message:op.name+": nearest parallel hole axis is offset by "+Units.format(closest,metric:metric)+". Align the patterns or part positions.")
        }
    }
}

extension Document {
    @discardableResult func setAssemblyRelation(_ relation: AssemblyRelation) -> Bool {
        guard !workspaceInspectionOnly else { return false }
        return transaction {
            var list = studio.relations ?? [];list.removeAll { $0.id == relation.id || ($0.target == relation.target && $0.axis == relation.axis) };list.append(relation);studio.relations = list
        }
    }
}
