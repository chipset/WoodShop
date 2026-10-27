import Foundation
import simd

enum FaceSketchShape: String,Codable,CaseIterable,Identifiable {
    case roundedRectangle = "Rounded rectangle",slot = "Slot",chamferedRectangle = "Chamfered rectangle"
    case rectangle = "Rectangle",ellipse = "Circle / ellipse",arc = "Arc",path = "Line / Bézier path"
    var id: String { rawValue }
}
enum FaceSketchMode: String,Codable,CaseIterable,Identifiable {
    case pocket = "Pocket",through = "Through-cut",groove = "Groove"
    var id: String { rawValue }
}
enum SketchDimension: String,Codable,CaseIterable,Identifiable {
    case corner = "Corner size"
    case centerU = "Center U",centerV = "Center V",width = "Width",height = "Height",depth = "Depth",grooveWidth = "Groove width",start = "Start angle",sweep = "Sweep angle"
    var id: String { rawValue }
    var angle: Bool { self == .start || self == .sweep }
}
struct SketchExpression: Codable,Equatable,Identifiable {
    var field: SketchDimension
    var expression: String
    var metricLiterals = false
    var id: String { field.rawValue }
}

/// A signed permutation of normalized face coordinates. Local rotations/mirrors
/// preserve the original sketch and expressions instead of baking its curves.
struct SketchOrientation: Codable,Equatable {
    var x = SIMD2<Double>(1,0)
    var y = SIMD2<Double>(0,1)
    var offset = SIMD2<Double>.zero
    var swapped: Bool { abs(x.y) > 0.5 }
    func map(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(simd_dot(x,p),simd_dot(y,p))+offset }
    func inverse(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let q = p-offset
        return SIMD2(x.x*q.x+y.x*q.y,x.y*q.x+y.y*q.y)
    }
    func followed(by next: SketchOrientation) -> SketchOrientation {
        let origin = next.map(map(.zero))
        let u = next.map(map(SIMD2(1,0)))-origin,v = next.map(map(SIMD2(0,1)))-origin
        return SketchOrientation(x:SIMD2(u.x,v.x),y:SIMD2(u.y,v.y),offset:origin)
    }
    var valid: Bool {
        let allowed = [-1.0,0,1]
        return [x.x,x.y,y.x,y.y].allSatisfy(allowed.contains) &&
            abs(simd_length_squared(x)-1)<1e-9 && abs(simd_length_squared(y)-1)<1e-9 && abs(simd_dot(x,y))<1e-9 &&
            offset == SIMD2(x.x < 0 || x.y < 0 ? 1 : 0,y.x < 0 || y.y < 0 ? 1 : 0)
    }
}

struct FaceSketch: Codable,Equatable {
    static let tolerance = 0.001 // inches; adaptive chord error for machining vectors
    var shape = FaceSketchShape.ellipse
    var mode = FaceSketchMode.pocket
    var center = SIMD2<Double>(3,3)
    var size = SIMD2<Double>(3,3)
    var depth = 0.25
    var grooveWidth = 0.25
    var startAngle = 0.0
    var sweepAngle = 180.0
    var nodes: [BoardProfile.Node] = []
    var closed = false
    var referenceFaceSize = SIMD2<Double>(12,12)
    var scaleWithFace = false
    var orientation = SketchOrientation()
    var expressions: [SketchExpression] = []
    var cornerSize: Double? = nil
    var keepCircular: Bool? = nil
    var islandInset: Double? = nil
    var constraints: [SketchConstraint]? = nil
    var concentricWith: UUID? = nil

    static func seed(part: Part,axis: Int) -> FaceSketch {
        var s = FaceSketch();let face = SIMD2(part.size[(axis+1)%3],part.size[(axis+2)%3])
        s.referenceFaceSize = face;s.center = face/2;s.size = face*0.4;s.depth = min(0.25,part.size[axis]/2)
        return s
    }
    var isClosed: Bool { shape == .rectangle || shape == .roundedRectangle || shape == .slot || shape == .chamferedRectangle || shape == .ellipse || (shape == .path && closed) }
    func value(_ field: SketchDimension) -> Double {
        switch field { case .corner:return cornerSize ?? min(size.x,size.y)/6;case .centerU:return center.x;case .centerV:return center.y;case .width:return size.x;case .height:return size.y;case .depth:return depth;case .grooveWidth:return grooveWidth;case .start:return startAngle;case .sweep:return sweepAngle }
    }
    mutating func set(_ field: SketchDimension,_ value: Double) {
        switch field { case .corner:cornerSize = value;case .centerU:center.x = value;case .centerV:center.y = value;case .width:size.x = value;case .height:size.y = value;case .depth:depth = value;case .grooveWidth:grooveWidth = value;case .start:startAngle = value;case .sweep:sweepAngle = value }
    }
    func evaluated(_ values: [String:Quantity]) throws -> FaceSketch {
        var s = self;var used: Set<SketchDimension> = []
        for binding in expressions {
            guard used.insert(binding.field).inserted else { throw ModelValidation.Failure(message:"A sketch dimension has more than one driving expression.") }
            let value = try Parametric.evaluate(DesignBinding(target:binding.field.angle ? .rotation : .size,expression:binding.expression,metricLiterals:binding.metricLiterals),values:values)
            s.set(binding.field,value)
        }
        return try SketchConstraints.apply(s)
    }
    func validation() -> String? {
        let numbers = [center.x,center.y,size.x,size.y,depth,grooveWidth,startAngle,sweepAngle,referenceFaceSize.x,referenceFaceSize.y]
        guard numbers.allSatisfy({ $0.isFinite && abs($0) <= 1e6 }),size.x > 0,size.y > 0,depth > 0,grooveWidth > 0,
              referenceFaceSize.x > 0,referenceFaceSize.y > 0,orientation.valid else { return "Sketch dimensions must be finite and positive, with a valid face coordinate frame." }
        guard nodes.count <= 64,nodes.allSatisfy({ node in
            [Optional(node.point),node.incoming,node.outgoing].compactMap { $0 }.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x)<1e6 && abs($0.y)<1e6 }
        }) else { return "Use up to 64 sketch points and finite curve handles." }
        if shape == .arc && (abs(sweepAngle)<0.01 || abs(sweepAngle)>=360) { return "An open arc needs a sweep between 0.01° and 359.99°. Use Circle / ellipse for a closed shape." }
        if shape == .path && nodes.count < (closed ? 3 : 2) { return closed ? "Add at least three points to close the sketch." : "Add at least two points to draw a path." }
        if let inset = islandInset,(!inset.isFinite || inset<=0 || mode != .pocket || !isClosed) { return "A raised island needs a positive border width inside a closed pocket." }
        if let corner = cornerSize,(!corner.isFinite || corner<=0 || corner>min(size.x,size.y)/2) { return "Corner size must be positive and fit within half the shape’s smaller dimension." }
        if mode != .groove && !isClosed { return "Close the path for a pocket or through-cut, or choose Groove for an open curve." }
        return nil
    }
    func shapeNodes() -> [BoardProfile.Node] {
        switch shape {
        case .roundedRectangle,.slot,.chamferedRectangle:
            return SketchCorners.rectangle(size:size,radius:shape == .slot ? min(size.x,size.y)/2 : (cornerSize ?? min(size.x,size.y)/6),chamfer:shape == .chamferedRectangle)
        case .path:return nodes
        case .rectangle:return [.init(point:.zero),.init(point:SIMD2(1,0)),.init(point:SIMD2(1,1)),.init(point:SIMD2(0,1))]
        case .ellipse:
            let k = 0.5522847498307936/2
            return [
                .init(point:SIMD2(1,0.5),incoming:SIMD2(1,0.5-k),outgoing:SIMD2(1,0.5+k)),
                .init(point:SIMD2(0.5,1),incoming:SIMD2(0.5+k,1),outgoing:SIMD2(0.5-k,1)),
                .init(point:SIMD2(0,0.5),incoming:SIMD2(0,0.5+k),outgoing:SIMD2(0,0.5-k)),
                .init(point:SIMD2(0.5,0),incoming:SIMD2(0.5-k,0),outgoing:SIMD2(0.5+k,0))]
        case .arc:
            guard startAngle.isFinite,sweepAngle.isFinite,abs(sweepAngle)<360,abs(sweepAngle)>0 else { return [] }
            let count = max(1,Int(ceil(abs(sweepAngle)/90))),step = sweepAngle * .pi/180/Double(count)
            var result: [BoardProfile.Node] = []
            for i in 0...count {
                let angle = startAngle * .pi/180+Double(i)*step,k = 4/3*tan(step/4)
                let point = SIMD2(0.5+cos(angle)/2,0.5+sin(angle)/2),tangent = SIMD2(-sin(angle),cos(angle))/2
                result.append(.init(point:point,incoming:i>0 ? point-k*tangent : nil,outgoing:i<count ? point+k*tangent : nil))
            }
            return result
        }
    }
    func facePoint(_ normalized: SIMD2<Double>,faceSize: SIMD2<Double>) -> SIMD2<Double> {
        let logical = orientation.swapped ? SIMD2(faceSize.y,faceSize.x) : faceSize
        let source = center+(normalized-SIMD2(repeating:0.5))*size
        return orientation.map(source/(scaleWithFace ? referenceFaceSize : logical))*faceSize
    }
    func sketchPoint(_ facePoint: SIMD2<Double>,faceSize: SIMD2<Double>) -> SIMD2<Double> {
        let logical = orientation.swapped ? SIMD2(faceSize.y,faceSize.x) : faceSize
        let source = orientation.inverse(facePoint/faceSize)*(scaleWithFace ? referenceFaceSize : logical)
        return (source-center)/size+SIMD2(repeating:0.5)
    }
    func path(faceSize: SIMD2<Double>) throws -> [SIMD2<Double>] {
        if shape == .ellipse || shape == .arc {
            let c = facePoint(SIMD2(repeating:0.5),faceSize:faceSize)
            let ru = facePoint(SIMD2(1,0.5),faceSize:faceSize)-c,rv = facePoint(SIMD2(0.5,1),faceSize:faceSize)-c
            let radius = max(simd_length(ru),simd_length(rv)),sweep = (shape == .ellipse ? 360 : sweepAngle) * .pi/180
            let step = 2*acos(max(-1,min(1,1-Self.tolerance/radius)))
            guard step.isFinite,step>0,abs(sweep)/step<500 else { throw ModelValidation.Failure(message:"This curve is too large for the machining tolerance. Use a smaller shape or split the arc.") }
            let count = max(4,Int(ceil(abs(sweep)/step))),start = (shape == .ellipse ? 0 : startAngle) * .pi/180
            return (0..<(shape == .ellipse ? count : count+1)).map { i in
                let angle = start+sweep*Double(i)/Double(count);return c+cos(angle)*ru+sin(angle)*rv
            }
        }
        let nodes = shapeNodes();guard let first = nodes.first else { return [] }
        var points = [facePoint(first.point,faceSize:faceSize)]
        func flatten(_ a: SIMD2<Double>,_ b: SIMD2<Double>,_ c: SIMD2<Double>,_ d: SIMD2<Double>,_ level: Int) throws {
            guard points.count < 480 else { throw ModelValidation.Failure(message:"This curve needs too many machining segments. Simplify it or split it into multiple sketches.") }
            func distance(_ p: SIMD2<Double>) -> Double {
                let edge = d-a,t = simd_length_squared(edge)>1e-20 ? max(0,min(1,simd_dot(p-a,edge)/simd_length_squared(edge))) : 0
                return simd_length(p-(a+edge*t))
            }
            if max(distance(b),distance(c)) <= Self.tolerance { points.append(d);return }
            guard level < 18 else { throw ModelValidation.Failure(message:"The curve cannot meet the machining tolerance. Reduce its size or simplify its handles.") }
            let ab = (a+b)/2,bc = (b+c)/2,cd = (c+d)/2,abc = (ab+bc)/2,bcd = (bc+cd)/2,mid = (abc+bcd)/2
            try flatten(a,ab,abc,mid,level+1);try flatten(mid,bcd,cd,d,level+1)
        }
        for i in 0..<(isClosed ? nodes.count : max(0,nodes.count-1)) {
            let a = nodes[i],b = nodes[(i+1)%nodes.count]
            if a.outgoing == nil && b.incoming == nil { points.append(facePoint(b.point,faceSize:faceSize)) }
            else { try flatten(facePoint(a.point,faceSize:faceSize),facePoint(a.outgoing ?? a.point,faceSize:faceSize),facePoint(b.incoming ?? b.point,faceSize:faceSize),facePoint(b.point,faceSize:faceSize),0) }
        }
        if isClosed { points.removeLast() }
        return points
    }
    func regions(faceSize: SIMD2<Double>) throws -> (outer:[SIMD2<Double>],islands:[[SIMD2<Double>]]) {
        if let message = validation() { throw ModelValidation.Failure(message:message) }
        let points = try path(faceSize:faceSize)
        var outer = points,holes: [[SIMD2<Double>]] = []
        if mode == .groove {
            if isClosed {
                outer = try Planar.offset(points,by:grooveWidth/2)
                holes = [try PocketRegion.inset(points,distance:grooveWidth/2)]
            } else { outer = try SketchStroke.outline(points,width:grooveWidth) }
        } else if let inset = islandInset { holes = [try PocketRegion.inset(points,distance:inset)] }
        guard (3...512).contains(outer.count),Planar.isSimple(outer),abs(Planar.signedArea(outer))>1e-8,
              holes.allSatisfy({ PocketRegion.validIsland($0,inside:outer) }) else { throw ModelValidation.Failure(message:"The sketch crosses itself or its island collapses. Move the points or reduce the border width.") }
        return (Planar.signedArea(outer)<0 ? Array(outer.reversed()) : outer,holes)
    }
    func contour(faceSize: SIMD2<Double>) throws -> [SIMD2<Double>] { try regions(faceSize:faceSize).outer }
    func generated(from operation: MachiningOperation,size: SIMD3<Double>,values: [String:Quantity],references: [MachiningOperation] = []) throws -> MachiningOperation {
        guard (0..<3).contains(operation.axis) else { throw ModelValidation.Failure(message:"Choose a valid sketch face.") }
        let evaluated = try resolved(values:values,operation:operation,stock:size,references:references)
        var next = operation
        let region = try evaluated.regions(faceSize:SIMD2(size[next.u],size[next.v]))
        next.contour = region.outer;next.islands = region.islands.isEmpty ? nil : region.islands
        next.depth = mode == .through ? size[next.axis] : evaluated.depth
        next.kind = mode == .through ? "Cutout" : (mode == .groove ? "Groove" : "Pocket")
        next.bottomScale = 1;next.bottomStretch = nil
        if let message = next.validation(size:size,checkStock:next.suppressed != true) { throw ModelValidation.Failure(message:message) }
        return next
    }
}

enum SketchStroke {
    /// Offset an open, non-self-intersecting path with bounded miter joins and round caps.
    /// Rejecting folds avoids silently machining the wrong area on a tight curve.
    static func outline(_ points: [SIMD2<Double>],width: Double) throws -> [SIMD2<Double>] {
        guard (2...240).contains(points.count),points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),width.isFinite,width>0,width<=1e6 else { throw ModelValidation.Failure(message:"Draw an open path and give the groove a positive width.") }
        let r = width/2
        var tangents: [SIMD2<Double>] = []
        for i in 0..<(points.count-1) {
            let delta = points[i+1]-points[i]
            guard simd_length(delta)>1e-7 else { throw ModelValidation.Failure(message:"Remove duplicate path points before creating a groove.") }
            tangents.append(simd_normalize(delta))
        }
        func normal(_ t: SIMD2<Double>) -> SIMD2<Double> { SIMD2(-t.y,t.x) }
        var left: [SIMD2<Double>] = [],right: [SIMD2<Double>] = []
        for i in points.indices {
            let previous = normal(tangents[max(0,i-1)]),next = normal(tangents[min(tangents.count-1,i)])
            let sum = previous+next
            guard simd_length(sum)>1e-5 else { throw ModelValidation.Failure(message:"The path doubles back. Open the bend or split the groove.") }
            let bisector = simd_normalize(sum),denominator = simd_dot(bisector,next)
            guard denominator>0.25 else { throw ModelValidation.Failure(message:"A groove corner is too sharp. Round the bend or split the groove.") }
            let offset = bisector*r/denominator
            left.append(points[i]+offset);right.append(points[i]-offset)
        }
        let capSteps = max(8,Int(ceil(.pi/acos(max(-1,min(1,1-FaceSketch.tolerance/r))))))
        guard 2*points.count+2*capSteps <= 512 else { throw ModelValidation.Failure(message:"This groove is too complex. Split the path into shorter sketches.") }
        func cap(_ center: SIMD2<Double>,from vector: SIMD2<Double>) -> [SIMD2<Double>] {
            let start = atan2(vector.y,vector.x)
            return (1..<capSteps).map { i in let a = start-Double(i) * .pi/Double(capSteps);return center+r*SIMD2(cos(a),sin(a)) }
        }
        return left+cap(points.last!,from:normal(tangents.last!))+right.reversed()+cap(points[0],from:-normal(tangents[0]))
    }
}
