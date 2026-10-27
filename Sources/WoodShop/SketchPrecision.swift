import Foundation
import simd

enum SketchConstraintKind: String,Codable,CaseIterable,Identifiable {
    case horizontal = "Horizontal",vertical = "Vertical",length = "Length",parallel = "Parallel",perpendicular = "Perpendicular",equalLength = "Equal length",fixedPoint = "Fixed point",tangent = "Tangent"
    var id: String { rawValue }
}
struct SketchConstraint: Codable,Equatable,Identifiable {
    var id = UUID()
    var kind: SketchConstraintKind
    var edge: Int
    var reference: Int? = nil
    var value: Double? = nil
    var point: SIMD2<Double>? = nil
}
enum SketchConstraints {
    /// Directed constraints keep the start point fixed and drive the next point.
    /// References must precede their dependent edge, so evaluation is deterministic.
    static func apply(_ input: FaceSketch) throws -> FaceSketch {
        var s = input
        if s.keepCircular == true { s.size.y = s.size.x }
        let constraints = s.constraints ?? []
        guard constraints.count<=128,Set(constraints.map(\.id)).count == constraints.count else { throw ModelValidation.Failure(message:"Too many or duplicate sketch constraints.") }
        guard constraints.isEmpty || s.shape == .path else { throw ModelValidation.Failure(message:"Point constraints apply to an editable Bézier path. Convert the shape first.") }
        var driven: Set<Int> = []
        func actual(_ p: SIMD2<Double>) -> SIMD2<Double> { s.center+(p-SIMD2(repeating:0.5))*s.size }
        for c in constraints.sorted(by: { ($0.edge,$0.kind == .tangent ? 1 : 0) < ($1.edge,$1.kind == .tangent ? 1 : 0) }) {
            guard c.edge>=0,c.edge<s.nodes.count else { throw ModelValidation.Failure(message:"A constraint refers to a removed point. Remove or reassign the constraint.") }
            if c.kind == .tangent {
                guard let incoming = s.nodes[c.edge].incoming else { throw ModelValidation.Failure(message:"Tangency needs an incoming curve handle. Curve the preceding edge first.") }
                let anchor = actual(s.nodes[c.edge].point),direction = anchor-actual(incoming),length = simd_length(direction)
                guard length>1e-8 else { throw ModelValidation.Failure(message:"Separate the incoming handle from its anchor before applying tangency.") }
                let reach = s.nodes[c.edge].outgoing.map { simd_length(actual($0)-anchor) } ?? length
                let p = anchor+direction/length*reach
                s.nodes[c.edge].outgoing = (p-s.center)/s.size+SIMD2(repeating:0.5)
                continue
            }
            guard c.edge+1<s.nodes.count,driven.insert(c.edge+1).inserted else { throw ModelValidation.Failure(message:"A point has conflicting constraints, or the closing edge creates a dependency cycle. Constrain an earlier edge or remove the conflicting constraint.") }
            let a = actual(s.nodes[c.edge].point),b = actual(s.nodes[c.edge+1].point),delta = b-a,length = simd_length(delta)
            guard length>1e-8 else { throw ModelValidation.Failure(message:"Separate duplicate points before constraining the edge.") }
            var end = b
            switch c.kind {
            case .horizontal:end = a+SIMD2(delta.x<0 ? -length : length,0)
            case .vertical:end = a+SIMD2(0,delta.y<0 ? -length : length)
            case .length:
                guard let value = c.value,value.isFinite,value>0,value<=1e6 else { throw ModelValidation.Failure(message:"Enter a positive constrained length.") }
                end = a+delta/length*value
            case .fixedPoint:
                guard let point = c.point,point.x.isFinite,point.y.isFinite else { throw ModelValidation.Failure(message:"Choose a finite fixed point.") };end = point
            case .parallel,.perpendicular,.equalLength:
                guard let j = c.reference,j>=0,j<c.edge,j+1<s.nodes.count else { throw ModelValidation.Failure(message:"Choose an earlier reference edge to avoid a constraint cycle.") }
                let reference = actual(s.nodes[j+1].point)-actual(s.nodes[j].point),r = simd_length(reference)
                guard r>1e-8 else { throw ModelValidation.Failure(message:"The reference edge has zero length.") }
                if c.kind == .equalLength { end = a+delta/length*r }
                else {
                    var direction = c.kind == .parallel ? reference/r : SIMD2(-reference.y,reference.x)/r
                    if simd_dot(direction,delta)<0 { direction = -direction };end = a+direction*length
                }
            case .tangent:break
            }
            let old = s.nodes[c.edge+1].point,p = (end-s.center)/s.size+SIMD2(repeating:0.5),shift = p-old
            s.nodes[c.edge+1].point = p;s.nodes[c.edge+1].incoming = s.nodes[c.edge+1].incoming.map { $0+shift };s.nodes[c.edge+1].outgoing = s.nodes[c.edge+1].outgoing.map { $0+shift }
        }
        return s
    }
}

struct SketchSnapPoint { var point: SIMD2<Double>;var label: String }
struct SketchSnapEdge { var a: SIMD2<Double>;var b: SIMD2<Double>;var label: String }
struct SketchSnapGeometry {
    var points: [SketchSnapPoint] = []
    var edges: [SketchSnapEdge] = []
    init(part: Part,axis: Int,excluding: UUID? = nil) {
        let u = (axis+1)%3,v = (axis+2)%3
        func add(_ contour: [SIMD2<Double>],_ name: String) {
            guard !contour.isEmpty else { return }
            let strideSize = max(1,contour.count/128)
            for i in Swift.stride(from:0,to:contour.count,by:strideSize) {
                let a = contour[i],b = contour[(i+1)%contour.count]
                points.append(SketchSnapPoint(point:a,label:name+" vertex"));points.append(SketchSnapPoint(point:(a+b)/2,label:name+" midpoint"))
            }
            for i in contour.indices { edges.append(SketchSnapEdge(a:contour[i],b:contour[(i+1)%contour.count],label:name+" edge")) }
        }
        var boundary = [SIMD2<Double>.zero,SIMD2(part.size[u],0),SIMD2(part.size[u],part.size[v]),SIMD2(0,part.size[v])]
        if let p = part.profile,p.thickness == axis { boundary = p.contour(size:part.size).map { p.u == u ? $0 : SIMD2($0.y,$0.x) } }
        add(boundary,"Stock");points.append(SketchSnapPoint(point:SIMD2(part.size[u],part.size[v])/2,label:"Stock center"))
        for op in part.machiningOperations where op.axis == axis && op.id != excluding && op.suppressed != true {
            points.append(SketchSnapPoint(point:op.openingBounds.center,label:op.name+" center"));add(op.contour,op.name)
            for hole in op.islands ?? [] { add(hole,op.name+" island") }
        }
    }
    func nearest(_ p: SIMD2<Double>,tolerance: Double) -> SketchSnapPoint? {
        if let point = points.filter({ simd_distance($0.point,p)<=tolerance }).min(by: { simd_distance_squared($0.point,p)<simd_distance_squared($1.point,p) }) { return point }
        var best: SketchSnapPoint?,distance = tolerance
        for edge in edges {
            let delta = edge.b-edge.a,t = max(0,min(1,simd_dot(p-edge.a,delta)/max(1e-20,simd_length_squared(delta)))),q = edge.a+delta*t,d = simd_distance(q,p)
            if d<distance { distance = d;best = SketchSnapPoint(point:q,label:edge.label) }
        }
        return best
    }
}

enum PocketRegion {
    static func disjoint(_ a: [SIMD2<Double>],_ b: [SIMD2<Double>]) -> Bool {
        if a.contains(where: { GeometryImport.contains($0,polygon:b) }) || b.contains(where: { GeometryImport.contains($0,polygon:a) }) { return false }
        for i in a.indices { for j in b.indices {
            let p = a[i],r = a[(i+1)%a.count]-p,q = b[j],s = b[(j+1)%b.count]-q,den = Planar.cross(r,s)
            if abs(den)>1e-12 {
                let t = Planar.cross(q-p,s)/den,u = Planar.cross(q-p,r)/den
                if t>=0,t<=1,u>=0,u<=1 { return false }
            }
        } }
        return true
    }
    static func validIsland(_ island: [SIMD2<Double>],inside outer: [SIMD2<Double>]) -> Bool {
        guard island.count>=3,island.count<=512,Planar.isSimple(island),abs(Planar.signedArea(island))>1e-8 else { return false }
        for i in island.indices {
            let a = island[i],b = island[(i+1)%island.count]
            guard a.x.isFinite,a.y.isFinite,GeometryImport.contains(a,polygon:outer),GeometryImport.contains((a+b)/2,polygon:outer) else { return false }
            for j in outer.indices {
                let c = outer[j],d = outer[(j+1)%outer.count],den = Planar.cross(b-a,d-c)
                if abs(den)>1e-12 {
                    let t = Planar.cross(c-a,d-c)/den,u = Planar.cross(c-a,b-a)/den
                    if t>=0,t<=1,u>=0,u<=1 { return false }
                }
            }
        }
        return true
    }
    static func inset(_ contour: [SIMD2<Double>],distance: Double) throws -> [SIMD2<Double>] {
        guard distance.isFinite,distance>0 else { throw ModelValidation.Failure(message:"Choose a positive border width.") }
        let ccw = Planar.signedArea(contour)<0 ? Array(contour.reversed()) : contour
        let convex = ccw.indices.allSatisfy { i in
            let a = ccw[i],b = ccw[(i+1)%ccw.count],c = ccw[(i+2)%ccw.count]
            return Planar.cross(b-a,c-b)>=(-1e-8)
        }
        let result: [SIMD2<Double>]
        if convex {
            var clipped = ccw
            for i in ccw.indices {
                let a = ccw[i],b = ccw[(i+1)%ccw.count],edge = b-a,limit = distance*simd_length(edge)
                let before = clipped
                clipped = []
                guard !before.isEmpty else { break }
                for j in before.indices {
                    let p = before[j],q = before[(j+1)%before.count],dp = Planar.cross(edge,p-a)-limit,dq = Planar.cross(edge,q-a)-limit
                    if dp>=(-1e-9) { clipped.append(p) }
                    if (dp<(-1e-9) && dq>1e-9) || (dp>1e-9 && dq<(-1e-9)) { clipped.append(p+(q-p)*(dp/(dp-dq))) }
                }
                var unique: [SIMD2<Double>] = []
                for point in clipped where unique.last.map({ simd_distance_squared($0,point)>1e-16 }) ?? true { unique.append(point) }
                if unique.count>1,simd_distance_squared(unique[0],unique.last!)<1e-16 { unique.removeLast() }
                clipped = unique
            }
            result = clipped
        } else { result = try Planar.offset(contour,by:-distance) }
        guard validIsland(result,inside:contour),abs(Planar.signedArea(result))<abs(Planar.signedArea(contour)) else { throw ModelValidation.Failure(message:"The border consumes the island or folds at a tight corner. Reduce its width or enlarge the shape.") }
        return result
    }
}

enum SketchCorners {
    static func rectangle(size: SIMD2<Double>,radius: Double,chamfer: Bool) -> [BoardProfile.Node] {
        let w = size.x,h = size.y,r = min(radius,min(w,h)/2),k = 0.5522847498307936
        let points = [SIMD2(r,0),SIMD2(w-r,0),SIMD2(w,r),SIMD2(w,h-r),SIMD2(w-r,h),SIMD2(r,h),SIMD2(0,h-r),SIMD2(0,r)]
        var nodes = points.map { BoardProfile.Node(point:$0/size) }
        if !chamfer {
            let directions = [SIMD2(1.0,0),SIMD2(0,1.0),SIMD2(-1.0,0),SIMD2(0,-1.0)]
            for corner in 0..<4 {
                let a = 2*corner+1,b = (a+1)%8
                nodes[a].outgoing = (points[a]+directions[corner]*r*k)/size
                nodes[b].incoming = (points[b]-directions[(corner+1)%4]*r*k)/size
            }
        }
        var result: [BoardProfile.Node] = []
        for node in nodes {
            if let last = result.last,simd_distance_squared(last.point,node.point)<1e-20 { result[result.count-1].outgoing = node.outgoing }
            else { result.append(node) }
        }
        if result.count>1,simd_distance_squared(result[0].point,result.last!.point)<1e-20 { result[0].incoming = result.removeLast().incoming }
        return result
    }
    static func trim(_ sketch: FaceSketch,index: Int,radius: Double,chamfer: Bool) throws -> FaceSketch {
        guard sketch.shape == .path,index>=0,index<sketch.nodes.count,(sketch.closed || (index>0 && index<sketch.nodes.count-1)),radius.isFinite,radius>0,
              (sketch.constraints ?? []).isEmpty else { throw ModelValidation.Failure(message:"Select an interior path corner and remove its constraints before adding a fillet or chamfer.") }
        var s = sketch;let previous = (index+s.nodes.count-1)%s.nodes.count,next = (index+1)%s.nodes.count
        guard s.nodes[previous].outgoing == nil,s.nodes[index].incoming == nil,s.nodes[index].outgoing == nil,s.nodes[next].incoming == nil else { throw ModelValidation.Failure(message:"Fillets and chamfers join straight edges. Use Bézier handles for an existing curved corner.") }
        func actual(_ p: SIMD2<Double>) -> SIMD2<Double> { s.center+(p-SIMD2(repeating:0.5))*s.size }
        let p = actual(s.nodes[index].point),a = actual(s.nodes[previous].point)-p,b = actual(s.nodes[next].point)-p,la = simd_length(a),lb = simd_length(b)
        guard la>1e-8,lb>1e-8 else { throw ModelValidation.Failure(message:"Separate duplicate points first.") }
        let u = a/la,v = b/lb,angle = acos(max(-1,min(1,simd_dot(u,v))))
        guard angle>0.01,angle<Double.pi-0.01 else { throw ModelValidation.Failure(message:"Choose a corner with two distinct directions.") }
        let trim = chamfer ? radius : radius/tan(angle/2)
        guard trim<min(la,lb)/2 else { throw ModelValidation.Failure(message:"The corner size consumes an adjacent edge. Use a smaller radius or chamfer.") }
        let entry = p+u*trim,exit = p+v*trim,k = 4/3*tan((Double.pi-angle)/4)*radius
        func normalized(_ p: SIMD2<Double>) -> SIMD2<Double> { (p-s.center)/s.size+SIMD2(repeating:0.5) }
        let first = BoardProfile.Node(point:normalized(entry),outgoing:chamfer ? nil : normalized(entry-u*k))
        let second = BoardProfile.Node(point:normalized(exit),incoming:chamfer ? nil : normalized(exit-v*k))
        s.nodes.replaceSubrange(index...index,with:[first,second]);return s
    }
}

extension FaceSketch {
    func resolved(values: [String:Quantity],operation: MachiningOperation,stock: SIMD3<Double>,references: [MachiningOperation]) throws -> FaceSketch {
        var result = try evaluated(values)
        if let reference = concentricWith {
            guard reference != operation.id,let target = references.first(where: { $0.id == reference }),target.axis == operation.axis else { throw ModelValidation.Failure(message:"The concentric reference is missing or on another face axis. Choose an available feature.") }
            guard !expressions.contains(where: { $0.field == .centerU || $0.field == .centerV }),!(constraints ?? []).contains(where: { $0.kind == .fixedPoint }) else { throw ModelValidation.Failure(message:"Concentric placement conflicts with a fixed point or center expression. Keep one placement rule.") }
            let face = SIMD2(stock[operation.u],stock[operation.v]),point = result.sketchPoint(target.openingBounds.center,faceSize:face)
            result.center += (point-SIMD2(repeating:0.5))*result.size
        }
        return result
    }
}
