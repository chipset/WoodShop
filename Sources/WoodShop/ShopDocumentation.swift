import AppKit
import UniformTypeIdentifiers

struct AssemblyStep: Codable,Equatable,Identifiable {
    var id = UUID()
    var text: String
    var parts: [UUID] = []
}
enum ShopIdentity {
    static func label(_ part: Part) -> String { part.shopNumber.map { String(format:"P%03d",$0) } ?? "P-" + part.id.uuidString.prefix(6) }
    static func numbered(_ input: Project) -> Project {
        var project = input
        var seen: Set<Int> = []
        let historic = (project.studio?.history ?? []).flatMap { $0.snapshot.parts.compactMap(\.shopNumber) }.max() ?? 0
        var next = max(project.studio?.nextShopNumber ?? 1,(project.parts.compactMap(\.shopNumber).max() ?? 0) + 1,historic+1)
        for i in project.parts.indices {
            if let number = project.parts[i].shopNumber,number > 0,seen.insert(number).inserted { continue }
            project.parts[i].shopNumber = next; seen.insert(next); next += 1
        }
        if !project.parts.isEmpty || project.studio?.nextShopNumber != nil {
            if project.studio == nil { project.studio = StudioState() }
            project.studio!.nextShopNumber = next
        }
        return project
    }
    static func suggestedSteps(_ project: Project) -> [AssemblyStep] {
        let parts = project.parts.filter { $0.hardware != true }
        var steps = [AssemblyStep(text:"Match each part to its label and cut-list identifier. Mark the CNC top face and grain direction before removing parts from the sheets.",parts:parts.map(\.id))]
        for joint in project.studio?.matingJoints ?? [] where !joint.suppressed {
            guard let shelf = parts.first(where: { $0.id == joint.shelf }),let receiver = parts.first(where: { $0.id == joint.receiver }) else { continue }
            steps.append(AssemblyStep(text:"Dry-fit \(label(shelf)) \(shelf.name) into \(joint.label) on \(label(receiver)) \(receiver.name). Pocket depth \(Units.format(joint.depth,metric:project.metric)); total fit allowance \(Units.format(joint.clearance,metric:project.metric)).",parts:[shelf.id,receiver.id]))
        }
        let groups = Dictionary(grouping:parts,by: { $0.group ?? "Assembly" })
        for group in groups.keys.sorted() { steps.append(AssemblyStep(text:"Dry-assemble \(group). Check mating surfaces, dimensions, and squareness before applying your chosen glue or fasteners.",parts:groups[group]!.map(\.id))) }
        steps.append(AssemblyStep(text:"Follow the intended fastening sequence, check square again, and install the back and hardware. Review the design's load and fastening requirements before use.",parts:parts.filter { $0.hardware == true || $0.name.localizedCaseInsensitiveContains("back") }.map(\.id)))
        return steps
    }
}
enum ShopDocuments {
    private static func text(_ string: String,_ rect: CGRect,size: CGFloat = 10,bold: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        (string as NSString).draw(in:rect,withAttributes:[.font:bold ? NSFont.boldSystemFont(ofSize:size) : NSFont.systemFont(ofSize:size),.foregroundColor:NSColor.black,.paragraphStyle:paragraph])
    }
    private static func pdf(_ draw: (CGContext,(_ title: String,_ body: () -> Void) -> Void) -> Void) -> Data {
        let data = NSMutableData(); var page = CGRect(x:0,y:0,width:612,height:792)
        guard let consumer = CGDataConsumer(data:data),let ctx = CGContext(consumer:consumer,mediaBox:&page,nil) else { return Data() }
        func newPage(_ title: String,_ body: () -> Void) {
            ctx.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx,flipped:false)
            text(title,CGRect(x:30,y:748,width:552,height:24),size:16,bold:true)
            body(); NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage()
        }
        draw(ctx,newPage); ctx.closePDF(); return data as Data
    }
    static func labels(project raw: Project) -> Data {
        let project = ShopIdentity.numbered(raw),parts = project.parts
        return pdf { ctx,page in
            for start in stride(from:0,to:max(1,parts.count),by:10) {
                page("\(parts.count) part labels — \(project.metric ? "mm" : "inches")") {
                    for (index,part) in parts.dropFirst(start).prefix(10).enumerated() {
                        let col = index % 2,row = index / 2,x = 30 + CGFloat(col) * 282,y = 610 - CGFloat(row) * 140
                        ctx.setStrokeColor(NSColor.gray.cgColor); ctx.stroke(CGRect(x:x,y:y,width:270,height:130))
                        text(ShopIdentity.label(part),CGRect(x:x+10,y:y+91,width:250,height:30),size:22,bold:true)
                        text(part.name,CGRect(x:x+10,y:y+66,width:250,height:24),size:12,bold:true)
                        let axes = part.materialAxes
                        let dimensions = [part.size[axes.l],part.size[axes.w],part.size[axes.t]].map { Units.format($0,metric:project.metric) }.joined(separator:" × ")
                        text("\(part.species.rawValue) · \(dimensions)\nGrain: \(FaceRef.axisNames[axes.l])  | CNC top: \(part.cncTopPositive == false ? "−" : "+")\(FaceRef.axisNames[axes.t])\n\(part.group ?? "")",CGRect(x:x+10,y:y+8,width:250,height:58),size:9)
                    }
                }
            }
        }
    }
    static func assembly(project raw: Project) -> Data {
        let project = ShopIdentity.numbered(raw),steps = project.studio?.assemblySteps ?? ShopIdentity.suggestedSteps(project)
        return pdf { _,page in
            for start in stride(from:0,to:max(1,steps.count),by:6) {
                page("Assembly sequence & joint callouts") {
                    for (index,step) in steps.dropFirst(start).prefix(6).enumerated() {
                        let refs = step.parts.compactMap { id in project.parts.first { $0.id == id } }.map { ShopIdentity.label($0) }.joined(separator:", ")
                        text("\(start + index + 1). \(step.text)",CGRect(x:30,y:630-CGFloat(index)*112,width:552,height:84),size:11,bold:false)
                        text(refs,CGRect(x:30,y:613-CGFloat(index)*112,width:552,height:14),size:9)
                    }
                }
            }
        }
    }
}
extension Document {
    func assignShopNumbers() {
        let numbered = ShopIdentity.numbered(project)
        if parts != numbered.parts { parts = numbered.parts }
        if studio.nextShopNumber != numbered.studio?.nextShopNumber { studio.nextShopNumber = numbered.studio?.nextShopNumber }
    }
    func exportShopLabels() { guard prepareForExport() else { return }; saveShopPDF(ShopDocuments.labels(project:fabricationSelectionProject),name:"Part labels.pdf") }
    func exportAssemblyGuide() { guard prepareForExport() else { return }; saveShopPDF(ShopDocuments.assembly(project:fabricationSelectionProject),name:"Assembly guide.pdf") }
    private func saveShopPDF(_ data: Data,name: String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = fileName + " " + name
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { try data.write(to:url,options:.atomic); status = "Saved " + name } catch { status = error.localizedDescription }
    }
}
