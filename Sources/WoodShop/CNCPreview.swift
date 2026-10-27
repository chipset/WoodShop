import SwiftUI

struct CNCPreview: View {
    @ObservedObject var doc: Document
    @State private var selectedSheet = 0
    @State private var showLabels = true
    @State private var editing: FeatureRef?
    @State private var setups = false
    private var error: String? { ModelValidation.nesting(sheetL:doc.sheetLength,sheetW:doc.sheetWidth,gap:doc.nestGap,registration:doc.studio.registration) }
    var body: some View {
        let result = CNCAnalysis.layout(doc.cncProject)
        let issues = CNCAnalysis.review(doc.cncProject)
        VStack(alignment:.leading,spacing:7) {
            HStack {
                Menu {
                    ForEach(doc.setupProfiles) { profile in Button(profile.name) { _ = doc.activateSetup(profile) } }
                    Divider()
                    Button("Manage saved setups…") { setups = true }
                } label: { Label(doc.studio.setupProfile?.name ?? "Choose CNC setup",systemImage:"slider.horizontal.3") }
                if doc.studio.setupProfile != nil { Button("Use measured thickness") { doc.applyMeasuredThickness() } }
                Spacer()
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            else {
                Picker("Machining setup",selection:$doc.cncSetup) { ForEach(CNCSetup.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                HStack {
                    Picker("Preview sheet",selection:$selectedSheet) {
                        ForEach(Array(result.sheets.enumerated()),id:\.offset) { index,sheet in
                            Text("\(Nesting.groupLabel(sheet.group,metric:doc.metric)) — \(result.stock(at:index)?.name ?? "Sheet") \(sheet.index+1)").tag(index)
                        }
                    }
                    Toggle("Labels",isOn:$showLabels)
                }
                HStack(spacing:8) {
                    let errors = issues.filter { $0.severity == .error }.count
                    let warnings = issues.filter { $0.severity == .warning }.count
                    Image(systemName:errors > 0 ? "xmark.octagon.fill" : (warnings > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle"))
                        .foregroundStyle(errors > 0 ? Color.red : (warnings > 0 ? .orange : .green))
                    Text("\(errors) errors · \(warnings) warnings").font(.caption)
                    Spacer()
                    Button("Review machining") { doc.fabricationTab = 2;doc.showReviewHighlights = true }.font(.caption)
                }.padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                GeometryReader { geometry in
                    Canvas { context,size in
                        guard !result.sheets.isEmpty else { return }
                        let index = max(0,min(selectedSheet,result.sheets.count-1)),sheet = result.sheets[index]
                        let stockL = result.stock(at:index)?.length ?? doc.sheetLength,stockW = result.stock(at:index)?.width ?? doc.sheetWidth
                        let scale = min((size.width-20)/stockL,(size.height-20)/stockW)
                        let origin = CGPoint(x:(size.width-stockL*scale)/2,y:(size.height-stockW*scale)/2)
                        func map(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x:origin.x+(p.x-sheet.x)*scale,y:origin.y+(stockW-p.y)*scale) }
                        let rect = CGRect(origin:origin,size:CGSize(width:stockL*scale,height:stockW*scale))
                        context.fill(Path(rect),with:.color(.brown.opacity(0.08))); context.stroke(Path(rect),with:.color(.secondary),lineWidth:1)
                        let subset = Nesting.Result(placed:result.placed.filter { $0.sheet == index },sheets:[sheet],sheetL:stockL,sheetW:stockW,oversize:[])
                        for primitive in CNCOut.prims(subset,metric:doc.metric,setup:doc.cncSetup,registration:doc.studio.registration) {
                            switch primitive {
                            case .poly(let layer,let points):
                                guard !points.isEmpty else { continue }
                                let color: Color = layer == "OUTLINE" ? .primary : (layer.hasPrefix("POCKET_BOTTOM") ? .purple : (layer.hasPrefix("SIDE") ? .orange : (layer == "CUTOUT_THROUGH" ? .red : .blue)))
                                var path = Path(); path.addLines(points.map(map)); path.closeSubpath()
                                if layer == "OUTLINE" { context.fill(path,with:.color(.brown.opacity(0.15))) }
                                context.stroke(path,with:.color(color),style:StrokeStyle(lineWidth:1,dash:layer.hasPrefix("POCKET_BOTTOM") ? [4,3] : []))
                            case .text(_,let point,_,let string):
                                if showLabels && point.y <= stockW { context.draw(Text(string).font(.system(size:9)),at:map(point),anchor:.bottomLeading) }
                            }
                        }
                        for placement in subset.placed {
                            if let id = placement.part.sourceID,doc.selectedIDs.contains(id) {
                                for outline in placement.part.cutOutlines {
                                    let points = outline.map { point -> CGPoint in
                                        let p = point+SIMD2(placement.x,placement.y)
                                        return map(doc.cncSetup == .bottom ? SIMD2(p.x,stockW-p.y) : p)
                                    }
                                    var path = Path();path.addLines(points);path.closeSubpath()
                                    context.stroke(path,with:.color(.accentColor),lineWidth:2)
                                }
                            }
                            for f in placement.part.features+placement.part.tenons {
                                let matching = issues.filter { $0.feature != nil && $0.feature == f.reference && $0.severity >= .warning }
                                let selected = f.reference != nil && f.reference == doc.selectedFeature
                                guard selected || !matching.isEmpty else { continue }
                                let a = f.rect.lo,b = f.rect.hi
                                let points = (f.polygon ?? [a,SIMD2(b.x,a.y),b,SIMD2(a.x,b.y)]).map { p -> SIMD2<Double> in
                                    let world = p+SIMD2(placement.x,placement.y); return doc.cncSetup == .bottom ? SIMD2(world.x,stockW-world.y) : world
                                }
                                var path = Path(); path.addLines(points.map(map)); path.closeSubpath()
                                let hasError = matching.contains { issue in issue.severity == .error }
                                let color: Color
                                if selected { color = .accentColor }
                                else if hasError { color = .red }
                                else { color = .orange }
                                context.stroke(path,with:.color(color),lineWidth:selected ? 3 : 2)
                            }
                            guard let source = placement.part.sourceID.flatMap(doc.part) else { continue }
                            for issue in issues where issue.part == source.id && issue.severity >= .warning {
                                let p = localToFlat(issue.point,source:source,flat:placement.part)+SIMD2(placement.x,placement.y)
                                let world = doc.cncSetup == .bottom ? SIMD2(p.x,stockW-p.y) : p
                                let at = map(world),color: Color = issue.severity == .error ? .red : .orange
                                context.fill(Path(ellipseIn:CGRect(x:at.x-6,y:at.y-6,width:12,height:12)),with:.color(color))
                                context.draw(Text("!").font(.system(size:10,weight:.bold)).foregroundColor(.white),at:at)
                            }
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in inspect(value.location,size:geometry.size,result:result) })
                    .accessibilityLabel("Interactive CNC layout. Click a hole, pocket, or relief to edit its definition.")
                }.frame(height:260).background(.background,in:RoundedRectangle(cornerRadius:5))
                Text("Click machining to edit • Blue: top pockets • Purple: bottom • Red/amber: review issues • Labels match the shop documents").font(.caption2).foregroundStyle(.secondary)
                if !result.oversize.isEmpty { Text("Cannot export — oversized: " + result.oversize.joined(separator:", ")).font(.caption).foregroundStyle(.red) }
                let notes = result.placed.flatMap { placement in placement.part.notes.map { "\(placement.part.name): \($0)" } }
                if !notes.isEmpty {
                    DisclosureGroup("Part setup notes (\(notes.count))") {
                        ScrollView { VStack(alignment:.leading,spacing:5) { ForEach(Array(notes.enumerated()),id:\.offset) { _,note in Text(note).font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:100)
                    }.font(.caption)
                }
            }
        }
        .onChange(of:result.sheets.count) { _,count in selectedSheet = max(0,min(selectedSheet,count-1)) }
        .sheet(item:$editing) { FeatureEditorSheet(doc:doc,reference:$0) }
        .sheet(isPresented:$setups) { SetupProfilesPanel(doc:doc) }
    }
    private func localToFlat(_ p: SIMD3<Double>,source:Part,flat:FlatPart) -> SIMD2<Double> {
        let axes = source.materialAxes
        var point = SIMD2(p[axes.l],p[axes.w]),length = source.size[axes.l],width = source.size[axes.w]
        if flat.flippedFace { point.y = width-point.y }
        for _ in 0..<(flat.rotationDegrees/90) { point = SIMD2(width-point.y,point.x); swap(&length,&width) }
        return point
    }
    private func inspect(_ point: CGPoint,size:CGSize,result:Nesting.Result) {
        guard !result.sheets.isEmpty else { return }
        let index = max(0,min(selectedSheet,result.sheets.count-1)),sheet = result.sheets[index]
        let stockL = result.stock(at:index)?.length ?? doc.sheetLength,stockW = result.stock(at:index)?.width ?? doc.sheetWidth
        let scale = min((size.width-20)/stockL,(size.height-20)/stockW)
        let origin = CGPoint(x:(size.width-stockL*scale)/2,y:(size.height-stockW*scale)/2)
        var world = SIMD2(sheet.x+(point.x-origin.x)/scale,stockW-(point.y-origin.y)/scale)
        if doc.cncSetup == .bottom { world.y = stockW-world.y }
        let placements = result.placed.filter { $0.sheet == index }
        if let ref = FeaturePicking.inLayout(point:world,placed:placements,setup:doc.cncSetup,threshold:4/scale) { doc.selectFeature(ref); editing = ref }
        else if let placement = placements.first(where: { p in p.part.cutOutlines.contains { GeometryImport.contains(world-SIMD2(p.x,p.y),polygon:$0) } }),let id = placement.part.sourceID { doc.select(id); doc.status = "Selected " + (doc.part(id).map { ShopIdentity.label($0) + " " + $0.name } ?? "part") }
    }
}
