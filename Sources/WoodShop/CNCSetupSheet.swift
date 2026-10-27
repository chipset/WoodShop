import AppKit

enum CNCSetupSheet {
    static func pdf(name: String,project: Project,layout: Nesting.Result,setup: CNCSetup,orientation: String) -> Data {
        let data = NSMutableData();var page = CGRect(x:0,y:0,width:612,height:792)
        guard let consumer = CGDataConsumer(data:data),let context = CGContext(consumer:consumer,mediaBox:&page,nil) else { return Data() }
        context.beginPDFPage(nil);NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
        context.setFillColor(NSColor.white.cgColor);context.fill(page)
        func text(_ string: String,x: CGFloat = 30,y: CGFloat,width: CGFloat = 552,height: CGFloat = 32,size: CGFloat = 10,bold: Bool = false) {
            let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
            (string as NSString).draw(in:CGRect(x:x,y:y,width:width,height:height),withAttributes:[.font:bold ? NSFont.boldSystemFont(ofSize:size) : NSFont.systemFont(ofSize:size),.foregroundColor:NSColor.black,.paragraphStyle:paragraph])
        }
        text("VCarve setup sheet",y:744,size:18,bold:true)
        text(name+".dxf",y:704,height:40,size:11,bold:true)
        text("Units: \(project.metric ? "millimeters" : "inches")  |  Stock: \(Units.format(layout.sheetL,metric:project.metric)) × \(Units.format(layout.sheetW,metric:project.metric))",y:676)
        if let flat = layout.placed.first?.part { text("Material: \(flat.species.rawValue)  |  Thickness: \(Units.format(flat.thickness,metric:project.metric))",y:650,height:22) }
        text(orientation,y:608,height:40)
        text("XY origin: bottom-left corner (X0 Y0). Set Z datum and cutting depths in VCarve for your fixture.",y:566,height:40)
        let scale = min(520/layout.sheetL,275/layout.sheetW)
        let origin = CGPoint(x:46,y:285)
        func point(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x:origin.x+p.x*scale,y:origin.y+p.y*scale) }
        context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(origin:origin,size:CGSize(width:layout.sheetL*scale,height:layout.sheetW*scale)))
        let primitives = CNCOut.prims(layout,metric:project.metric,setup:setup,registration:project.studio?.registration ?? Registration())
        var layers: Set<String> = []
        for primitive in primitives {
            switch primitive {
            case .poly(let layer,let points):
                layers.insert(layer)
                guard let first = points.first else { continue }
                context.beginPath();context.move(to:point(first));for p in points.dropFirst() { context.addLine(to:point(p)) };context.closePath()
                context.setStrokeColor((layer == "OUTLINE" || layer == "SHEET" || layer == "REFERENCE_OUTLINE" ? NSColor.darkGray : NSColor.systemBlue).cgColor);context.setLineWidth(layer == "OUTLINE" ? 0.8 : 0.45);context.strokePath()
            case .text(_,let at,_,let string):
                guard at.y <= layout.sheetW else { continue }
                let p = point(at);text(string,x:p.x,y:p.y,width:130,height:12,size:6)
            }
        }
        context.setStrokeColor(NSColor.systemRed.cgColor);context.setLineWidth(1.5)
        context.move(to:origin);context.addLine(to:CGPoint(x:origin.x+35,y:origin.y));context.move(to:origin);context.addLine(to:CGPoint(x:origin.x,y:origin.y+35));context.strokePath()
        text("X →",x:origin.x+35,y:origin.y-6,width:35,height:14,size:8)
        text("Y ↑",x:origin.x-15,y:origin.y+36,width:30,height:14,size:8)
        text("0,0",x:origin.x-15,y:origin.y-18,width:40,height:14,size:8,bold:true)
        text("Cutting layers: "+layers.filter { !["SHEET","LABELS","TENON","REFERENCE_OUTLINE"].contains($0) }.sorted().joined(separator:", "),y:210,height:60,size:9)
        text("Reference layers: SHEET, LABELS, TENON, REFERENCE_OUTLINE. Exclude these from cutting toolpaths. Relief is included in the geometry; do not add dogbones twice.",y:158,height:45,size:9)
        text("Create and simulate toolpaths in VCarve. Add tabs and workholding, choose cutters and feeds, then post for your machine. Run the final through profile after both faces are complete.",y:98,height:50,size:10)
        NSGraphicsContext.restoreGraphicsState();context.endPDFPage();context.closePDF();return data as Data
    }
}
