import AppKit
import PDFKit
import simd

enum ExplodedGuide {
    private static func label(_ string: String,_ rect: CGRect,size: CGFloat = 10,bold: Bool = false,color: NSColor = .black) {
        let style = NSMutableParagraphStyle();style.lineBreakMode = .byWordWrapping
        (string as NSString).draw(in:rect,withAttributes:[.font:bold ? NSFont.boldSystemFont(ofSize:size) : NSFont.systemFont(ofSize:size),.foregroundColor:color,.paragraphStyle:style])
    }
    private static func projection(_ point: SIMD3<Double>) -> CGPoint {
        CGPoint(x:(point.x-point.z)*0.8660254,y:point.y+(point.x+point.z)*0.5)
    }
    private static func corners(_ part: Part) -> [CGPoint] {
        (0..<8).map { i in
            projection(part.toWorld(SIMD3(i & 1 == 0 ? 0 : part.size.x,i & 2 == 0 ? 0 : part.size.y,i & 4 == 0 ? 0 : part.size.z)))
        }
    }
    private static let edges: [(Int,Int)] = [(0,1),(0,2),(0,4),(1,3),(1,5),(2,3),(2,6),(3,7),(4,5),(4,6),(5,7),(6,7)]
    private static func arrow(_ ctx: CGContext,from a: CGPoint,to b: CGPoint) {
        let dx = b.x-a.x,dy = b.y-a.y,len = max(hypot(dx,dy),1)
        ctx.move(to:a);ctx.addLine(to:b);ctx.strokePath()
        let ux = dx/len,uy = dy/len
        for sign: CGFloat in [-1,1] {
            ctx.move(to:b);ctx.addLine(to:CGPoint(x:b.x-ux*8-uy*4*sign,y:b.y-uy*8+ux*4*sign));ctx.strokePath()
        }
    }
    private static func details(project: Project) -> Data {
        let all = project.parts.filter { $0.hardware != true }
        let custom = project.studio?.assemblySteps
        var steps = custom ?? ShopIdentity.suggestedSteps(project)
        if custom == nil,steps.count > 1,steps.first?.parts.count == all.count { steps.removeFirst() }
        if custom != nil {
            let covered = Set(steps.flatMap(\.parts))
            if all.contains(where: { !covered.contains($0.id) }) {
                steps += ShopIdentity.suggestedSteps(project).dropFirst().filter { step in step.parts.contains { !covered.contains($0) } }
            }
        }
        if steps.isEmpty { steps = [AssemblyStep(text:"Dry-fit the parts in the numbered sequence and check dimensions and squareness.",parts:all.map(\.id))] }
        let lookup = Dictionary(uniqueKeysWithValues:all.map { ($0.id,$0) })
        let output = NSMutableData();var media = CGRect(x:0,y:0,width:792,height:612)
        guard let consumer = CGDataConsumer(data:output),let ctx = CGContext(consumer:consumer,mediaBox:&media,nil) else { return Data() }
        let notes = (custom ?? []).filter { $0.parts.isEmpty }
        for start in stride(from:0,to:notes.count,by:5) {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx,flipped:false)
            label("Project assembly and source notes",CGRect(x:32,y:566,width:728,height:30),size:18,bold:true)
            for (index,note) in notes.dropFirst(start).prefix(5).enumerated() {
                let y = 465-CGFloat(index)*103
                label("\(start+index+1).  "+note.text,CGRect(x:42,y:y,width:705,height:84),size:10)
            }
            NSGraphicsContext.restoreGraphicsState();ctx.endPDFPage()
        }
        for (stepIndex,step) in steps.enumerated() {
            let selected = step.parts.compactMap { lookup[$0] }
            guard !selected.isEmpty else { continue }
            for chunkStart in stride(from:0,to:selected.count,by:6) {
                let group = Array(selected.dropFirst(chunkStart).prefix(6))
                ctx.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx,flipped:false)
                label("Assembly step \(stepIndex+1) · exploded parts",CGRect(x:32,y:570,width:728,height:26),size:18,bold:true)
                label(step.text,CGRect(x:32,y:521,width:728,height:45),size:10)
                label("Diagram shows approximate separation and return arrows. Use the dimensions and part IDs at right for fabrication.",CGRect(x:32,y:500,width:728,height:16),size:8,color:.darkGray)
                let drawings = group.map(corners)
                let centers = group.map { projection($0.center) }
                let spread = max(1,drawings.flatMap { $0 }.map(\.x).max()! - drawings.flatMap { $0 }.map(\.x).min()!)
                let offsets = group.indices.map { i -> CGPoint in
                    let angle = Double(i)*2.399963229728653
                    return CGPoint(x:cos(angle)*spread*0.22,y:sin(angle)*spread*0.22)
                }
                let shifted = drawings.enumerated().map { i,points in points.map { CGPoint(x:$0.x+offsets[i].x,y:$0.y+offsets[i].y) } }
                let extent = (shifted.flatMap { $0 }+centers)
                let minX = extent.map(\.x).min() ?? 0,maxX = extent.map(\.x).max() ?? 1
                let minY = extent.map(\.y).min() ?? 0,maxY = extent.map(\.y).max() ?? 1
                let scale = min(420/max(maxX-minX,1),410/max(maxY-minY,1))
                func map(_ point: CGPoint) -> CGPoint { CGPoint(x:45+(point.x-minX)*scale,y:55+(point.y-minY)*scale) }
                ctx.setLineWidth(1)
                for i in group.indices {
                    let points = shifted[i].map(map),target = map(centers[i])
                    let partColor = NSColor(calibratedHue:CGFloat(i)/CGFloat(max(group.count,1)),saturation:0.48,brightness:0.68,alpha:1)
                    ctx.setStrokeColor(partColor.cgColor)
                    for (a,b) in edges { ctx.move(to:points[a]);ctx.addLine(to:points[b]);ctx.strokePath() }
                    let center = map(CGPoint(x:shifted[i].map(\.x).reduce(0,+)/8,y:shifted[i].map(\.y).reduce(0,+)/8))
                    ctx.setStrokeColor(NSColor.darkGray.cgColor)
                    if hypot(center.x-target.x,center.y-target.y)>10 { arrow(ctx,from:center,to:target) }
                    label(ShopIdentity.label(group[i]),CGRect(x:center.x-20,y:center.y+8,width:90,height:14),size:9,bold:true,color:partColor)
                }
                ctx.setStrokeColor(NSColor.lightGray.cgColor);ctx.stroke(CGRect(x:25,y:45,width:500,height:444))
                label("PARTS AND FINISHED CORE DIMENSIONS",CGRect(x:542,y:473,width:220,height:17),size:10,bold:true)
                for (i,part) in group.enumerated() {
                    let top = 443-CGFloat(i)*67,axes = part.materialAxes
                    label(ShopIdentity.label(part)+"  "+part.name,CGRect(x:542,y:top,width:220,height:30),size:10,bold:true)
                    let dims = [part.size[axes.l],part.size[axes.w],part.size[axes.t]].map { Units.format($0,metric:project.metric) }.joined(separator:" × ")
                    label("L × W × T: "+dims,CGRect(x:542,y:top-15,width:220,height:17),size:8)
                    label("Material: "+part.species.rawValue+" · Grain: "+FaceRef.axisNames[axes.l],CGRect(x:542,y:top-29,width:220,height:17),size:8,color:.darkGray)
                }
                label("Page for parts \(chunkStart+1)–\(chunkStart+group.count) of \(selected.count) in step \(stepIndex+1)",CGRect(x:32,y:17,width:728,height:17),size:8,color:.darkGray)
                NSGraphicsContext.restoreGraphicsState();ctx.endPDFPage()
            }
        }
        ctx.closePDF();return output as Data
    }
    static func pdf(project input: Project) -> Data {
        let project = ShopIdentity.numbered(input),parts = project.parts.filter { $0.hardware != true }
        let overview = Drawing.pdf(parts:parts,title:"Exploded assembly · assembled reference",metric:project.metric,overviewOnly:true)
        guard let document = PDFDocument(data:overview),let detail = PDFDocument(data:details(project:project)) else { return overview }
        while let page = detail.page(at:0) { detail.removePage(at:0);document.insert(page,at:document.pageCount) }
        return document.dataRepresentation() ?? overview
    }
}
