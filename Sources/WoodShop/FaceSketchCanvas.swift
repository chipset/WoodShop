import SwiftUI
import AppKit

private struct SketchCanvasLayout {
    let face: SIMD2<Double>
    let rect: CGRect
    init(canvas: CGSize,face: SIMD2<Double>,zoom: Double,pan: CGSize) {
        self.face = face
        let scale = max(0.01,min((canvas.width-80)/face.x,(canvas.height-80)/face.y))*zoom
        let size = CGSize(width:face.x*scale,height:face.y*scale)
        rect = CGRect(x:(canvas.width-size.width)/2+pan.width,y:(canvas.height-size.height)/2+pan.height,width:size.width,height:size.height)
    }
    func map(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x:rect.minX+p.x/face.x*rect.width,y:rect.maxY-p.y/face.y*rect.height) }
    func unmap(_ p: CGPoint) -> SIMD2<Double> { SIMD2((p.x-rect.minX)/rect.width*face.x,(rect.maxY-p.y)/rect.height*face.y) }
}

struct FaceSketchCanvas: View {
    @Binding var sketch: FaceSketch
    @Binding var selected: Int?
    @Binding var tool: FaceSketchTool
    var evaluated: FaceSketch? = nil
    var snapGeometry: SketchSnapGeometry? = nil
    let faceSize: SIMD2<Double>
    let profile: BoardProfile?
    let partSize: SIMD3<Double>
    let axis: Int
    let snap: Double?
    let metric: Bool
    let onBegin: () -> Void
    let onEnd: () -> Void
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var dragBefore: FaceSketch?
    @State private var panBefore: CGSize?
    @State private var cursor: SIMD2<Double>?
    @State private var snapLabel = ""
    @State private var snapTolerance = 0.1
    private var display: FaceSketch { evaluated ?? sketch }
    private var frameDriven: Bool { sketch.expressions.contains { [.centerU,.centerV,.width,.height].contains($0.field) } }
    var body: some View {
        GeometryReader { geometry in
            let layout = SketchCanvasLayout(canvas:geometry.size,face:faceSize,zoom:zoom,pan:pan)
            ZStack(alignment:.topLeading) {
                Canvas { context,size in draw(context:&context,size:size,layout:layout) }
                    .background(Color(nsColor:.textBackgroundColor))
                    .contentShape(Rectangle())
                    .gesture(drawGesture(layout))
                if tool == .select || tool == .pen {
                    if sketch.shape == .path {
                        ForEach(Array(sketch.nodes.indices),id:\.self) { index in
                            pointHandle(index,layout:layout)
                            if selected == index {
                                if sketch.nodes[index].incoming != nil { curveHandle(index,incoming:true,layout:layout) }
                                if sketch.nodes[index].outgoing != nil { curveHandle(index,incoming:false,layout:layout) }
                            }
                        }
                    } else if !frameDriven {
                        Image(systemName:"arrow.up.and.down.and.arrow.left.and.right").font(.caption).foregroundStyle(Color.accentColor)
                            .padding(8).background(.regularMaterial,in:Circle()).contentShape(Circle())
                            .position(layout.map(display.facePoint(SIMD2(repeating:0.5),faceSize:faceSize)))
                            .gesture(centerGesture(layout))
                            .accessibilityLabel("Move sketch shape")
                    }
                }
                HStack(spacing:8) {
                    Label(snapLabel.isEmpty ? "Face coordinates" : snapLabel,systemImage:snapLabel.isEmpty ? "viewfinder" : "scope").font(.caption)
                    if let cursor { Text("U "+Units.format(cursor.x,metric:metric)+" · V "+Units.format(cursor.y,metric:metric)).font(.caption.monospacedDigit()) }
                }.padding(9).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).padding(12).allowsHitTesting(false)
                VStack {
                    Spacer()
                    HStack {
                        if frameDriven { Label("Frame driven by parameters",systemImage:"link").font(.caption).padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)) }
                        Spacer()
                        HStack(spacing:10) {
                            Button { zoom = max(0.5,zoom/1.3) } label: { Image(systemName:"minus.magnifyingglass") }.help("Zoom out")
                            Text("\(Int(zoom*100))%").font(.caption.monospacedDigit()).frame(width:40)
                            Button { zoom = min(8,zoom*1.3) } label: { Image(systemName:"plus.magnifyingglass") }.help("Zoom in")
                            Button("Fit") { zoom = 1;pan = .zero }
                        }.buttonStyle(.plain).padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))
                    }.padding(12)
                }
            }.clipped().coordinateSpace(name:"faceSketchCanvas")
        }.accessibilityLabel("Face sketch drawing canvas. Use the drawing toolbar, then edit dimensions or individual path points.")
    }
    private func draw(context: inout GraphicsContext,size: CGSize,layout: SketchCanvasLayout) {
        var board = Path()
        if let profile,profile.thickness == axis {
            let points = profile.contour(size:partSize).map { p in profile.u == (axis+1)%3 ? p : SIMD2(p.y,p.x) }
            board.addLines(points.map(layout.map));board.closeSubpath()
        } else { board = Path(layout.rect) }
        context.fill(board,with:.color(.brown.opacity(0.08)))
        var grid = Path()
        let spacing = max(snap ?? 0.0625,pow(2,ceil(log2(max(faceSize.x,faceSize.y)/24))))
        for i in 0...min(200,Int(faceSize.x/spacing)) { let u = Double(i)*spacing;grid.move(to:layout.map(SIMD2(u,0)));grid.addLine(to:layout.map(SIMD2(u,faceSize.y))) }
        for i in 0...min(200,Int(faceSize.y/spacing)) { let v = Double(i)*spacing;grid.move(to:layout.map(SIMD2(0,v)));grid.addLine(to:layout.map(SIMD2(faceSize.x,v))) }
        var clipped = context;clipped.clip(to:board);clipped.stroke(grid,with:.color(.secondary.opacity(0.15)),lineWidth:0.5)
        context.stroke(board,with:.color(.secondary),lineWidth:1)
        let origin = layout.map(.zero)
        context.draw(Text("0,0").font(.caption2.monospaced()).foregroundColor(.secondary),at:CGPoint(x:origin.x-5,y:origin.y+14),anchor:.topTrailing)
        context.draw(Text(Units.format(faceSize.x,metric:metric)).font(.caption),at:CGPoint(x:layout.rect.midX,y:layout.rect.maxY+17))
        context.draw(Text(Units.format(faceSize.y,metric:metric)).font(.caption),at:CGPoint(x:layout.rect.minX-8,y:layout.rect.midY),anchor:.trailing)
        if let regions = try? display.regions(faceSize:faceSize) {
            var region = Path();region.addLines(regions.outer.map(layout.map));region.closeSubpath()
            for hole in regions.islands { region.addLines(hole.map(layout.map));region.closeSubpath() }
            context.fill(region,with:.color(.accentColor.opacity(display.mode == .through ? 0.25 : 0.13)),style:FillStyle(eoFill:true))
            context.stroke(region,with:.color(.accentColor),lineWidth:1.5)
        }
        let nodes = display.shapeNodes()
        if let first = nodes.first {
            var path = Path();path.move(to:layout.map(display.facePoint(first.point,faceSize:faceSize)))
            for i in 0..<(display.isClosed ? nodes.count : max(0,nodes.count-1)) {
                let a = nodes[i],b = nodes[(i+1)%nodes.count]
                if a.outgoing == nil && b.incoming == nil { path.addLine(to:layout.map(display.facePoint(b.point,faceSize:faceSize))) }
                else { path.addCurve(to:layout.map(display.facePoint(b.point,faceSize:faceSize)),control1:layout.map(display.facePoint(a.outgoing ?? a.point,faceSize:faceSize)),control2:layout.map(display.facePoint(b.incoming ?? b.point,faceSize:faceSize))) }
            }
            if display.isClosed { path.closeSubpath() }
            context.stroke(path,with:.color((try? display.contour(faceSize:faceSize)) == nil ? .red : .accentColor),style:StrokeStyle(lineWidth:1.5,dash:display.mode == .groove ? [5,3] : []))
        }
        if let selected,display.nodes.indices.contains(selected) {
            let node = display.nodes[selected],anchor = layout.map(display.facePoint(node.point,faceSize:faceSize))
            var handles = Path()
            for handle in [node.incoming,node.outgoing].compactMap({$0}) { handles.move(to:anchor);handles.addLine(to:layout.map(display.facePoint(handle,faceSize:faceSize))) }
            context.stroke(handles,with:.color(.blue.opacity(0.7)),lineWidth:1)
        }
    }
    private func snapped(_ point: SIMD2<Double>,from start: SIMD2<Double>? = nil) -> SIMD2<Double> {
        var p = point
        snapLabel = ""
        if let snap,snap>0,!NSEvent.modifierFlags.contains(.option) {
            if let target = snapGeometry?.nearest(point,tolerance:snapTolerance) { p = target.point;snapLabel = target.label }
            else { p = SIMD2((p.x/snap).rounded()*snap,(p.y/snap).rounded()*snap) }
        }
        if let start,NSEvent.modifierFlags.contains(.shift) {
            if abs(p.x-start.x)>abs(p.y-start.y) { p.y = start.y } else { p.x = start.x }
        }
        return p
    }
    private func start() { if dragBefore == nil { dragBefore = sketch;onBegin() } }
    private func finish() { dragBefore = nil;panBefore = nil;onEnd() }
    private func drawGesture(_ layout: SketchCanvasLayout) -> some Gesture {
        DragGesture(minimumDistance:0,coordinateSpace:.named("faceSketchCanvas")).onChanged { value in
            snapTolerance = faceSize.x/layout.rect.width*8
            cursor = snapped(layout.unmap(value.location))
            if tool == .pan { if panBefore == nil { panBefore = pan };pan = CGSize(width:panBefore!.width+value.translation.width,height:panBefore!.height+value.translation.height);return }
            guard tool != .select,tool != .pen,!frameDriven else { return }
            start()
            let a = snapped(layout.unmap(value.startLocation)),raw = snapped(layout.unmap(value.location))
            var b = raw
            if NSEvent.modifierFlags.contains(.shift),tool != .line {
                let side = max(abs(b.x-a.x),abs(b.y-a.y));b = a+SIMD2(b.x>=a.x ? side : -side,b.y>=a.y ? side : -side)
            } else if tool == .line { b = snapped(raw,from:a) }
            var s = dragBefore!
            s.orientation = SketchOrientation();s.referenceFaceSize = faceSize
            if tool == .line {
                s.shape = .path;s.mode = .groove;s.closed = false;s.center = faceSize/2;s.size = faceSize
                s.nodes = [.init(point:a/faceSize),.init(point:b/faceSize)]
            } else {
                s.center = (a+b)/2;s.size = SIMD2(max(0.0001,abs(b.x-a.x)),max(0.0001,abs(b.y-a.y)))
                s.shape = tool == .rectangle ? .rectangle : (tool == .ellipse ? .ellipse : .arc)
                if tool == .arc { s.mode = .groove } else if s.mode == .groove { s.mode = .pocket }
            }
            if s.mode != .pocket || !s.isClosed { s.islandInset = nil };s.constraints = nil;s.keepCircular = nil;s.concentricWith = nil
            sketch = s
        }.onEnded { value in
            if tool == .pen {
                guard sketch.nodes.count<64 else { return }
                start();let point = snapped(layout.unmap(value.location))
                sketch.nodes.append(.init(point:display.sketchPoint(point,faceSize:faceSize)));selected = sketch.nodes.count-1
            } else if tool == .select { selected = nil }
            finish()
        }
    }
    private func pointHandle(_ index: Int,layout: SketchCanvasLayout) -> some View {
        Circle().fill(selected == index ? Color.accentColor : Color(nsColor:.windowBackgroundColor)).overlay(Circle().strokeBorder(Color.accentColor,lineWidth:1.5)).frame(width:12,height:12)
            .padding(5).contentShape(Circle()).position(layout.map(display.facePoint(display.nodes[index].point,faceSize:faceSize)))
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("faceSketchCanvas")).onChanged { value in
                selected = index;start();guard let before = dragBefore else { return }
                let p = snapped(layout.unmap(value.location)),normalized = display.sketchPoint(p,faceSize:faceSize),delta = normalized-before.nodes[index].point
                var s = before;s.nodes[index].point = normalized;s.nodes[index].incoming = before.nodes[index].incoming.map { $0+delta };s.nodes[index].outgoing = before.nodes[index].outgoing.map { $0+delta };sketch = s
            }.onEnded { _ in finish() })
            .accessibilityLabel("Sketch point \(index+1)")
    }
    private func curveHandle(_ index: Int,incoming: Bool,layout: SketchCanvasLayout) -> some View {
        let point = incoming ? display.nodes[index].incoming! : display.nodes[index].outgoing!
        return Circle().fill(.blue).frame(width:9,height:9).padding(5).contentShape(Circle())
            .position(layout.map(display.facePoint(point,faceSize:faceSize)))
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("faceSketchCanvas")).onChanged { value in
                start();let normalized = display.sketchPoint(snapped(layout.unmap(value.location)),faceSize:faceSize)
                if incoming { sketch.nodes[index].incoming = normalized } else { sketch.nodes[index].outgoing = normalized }
            }.onEnded { _ in finish() }).accessibilityLabel(incoming ? "Incoming curve handle" : "Outgoing curve handle")
    }
    private func centerGesture(_ layout: SketchCanvasLayout) -> some Gesture {
        DragGesture(minimumDistance:0,coordinateSpace:.named("faceSketchCanvas")).onChanged { value in
            start();guard let before = dragBefore else { return }
            let from = layout.unmap(value.startLocation),to = snapped(layout.unmap(value.location),from:from)
            let original = before.facePoint(SIMD2(repeating:0.5),faceSize:faceSize),goal = original+(to-from)
            var s = before;s.center += (before.sketchPoint(goal,faceSize:faceSize)-SIMD2(repeating:0.5))*before.size;sketch = s
        }.onEnded { _ in finish() }
    }
}
