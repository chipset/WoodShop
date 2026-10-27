import SwiftUI
import AppKit

enum FabricationPage: Int, CaseIterable, Identifiable {
    case cutList, layout, review, assembly, job, handoff
    var id: Int { rawValue }
    var title: String {
        switch self { case .cutList: return "Cut list"; case .layout: return "Sheet layout"; case .review: return "Machining review"; case .assembly: return "Labels & assembly";case .job:return "Prepare CNC job";case .handoff:return "Open in VCarve" }
    }
    var symbol: String {
        switch self { case .cutList: return "list.bullet.rectangle"; case .layout: return "square.grid.3x3"; case .review: return "checkmark.shield"; case .assembly: return "tag";case .job:return "checklist";case .handoff:return "arrow.up.forward.app" }
    }
    var detail: String {
        switch self {
        case .cutList: return "Stock sizes and quantities, grouped by material and machining."
        case .layout: return "Set your sheet size, then inspect each sheet and machining face."
        case .review: return "Resolve errors and inspect warnings before exporting to VCarve."
        case .assembly: return "Keep part labels and assembly instructions together."
        case .job:return "Follow the steps to prepare a job for your CNC."
        case .handoff:return "Import the right files with matching units, stock, and origin."
        }
    }
}

struct CutListView: View {
    @ObservedObject var doc: Document
    @State private var search = ""
    @State private var selectedRows: Set<String> = []
    @State private var warningsReviewed = false
    @State private var expandedSections: Set<MakeSection> = [.cnc]
    private var page: FabricationPage { FabricationPage(rawValue:doc.fabricationTab) ?? .cutList }
    private var route: MakeRoute { MakeRoute.current(doc) }
    var body: some View {
        let rows = doc.makeArea == .fabrication ? CutList.rows(doc.cncProject.parts) : []
        let preflight = doc.makeArea == .fabrication ? CNCPreflight(project:doc.cncProject) : nil
        VStack(spacing:0) {
            HStack(spacing:14) {
                Image(systemName:"square.grid.3x3").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment:.leading,spacing:3) {
                    Text("Make").font(.title2.bold())
                    Text(doc.fileName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Picker("Units",selection:$doc.metric) { Text("Inches").tag(false);Text("Millimeters").tag(true) }.pickerStyle(.segmented).frame(width:190)
                Button("Done") { doc.showCutList = false }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing:0) {
                makeSidebar
                Divider()
                VStack(alignment:.leading,spacing:12) {
                    if doc.makeArea == .shop { shopContent }
                    else {
                        Text(page.title).font(.title3.bold())
                        Text(page.detail).font(.callout).foregroundStyle(.secondary)
                        fabricationContent(rows)
                    }
                }.padding(doc.makeArea == .shop ? 0 : 20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }
            Divider()
            HStack(spacing:12) {
                Text(doc.status == doc.tool.hint ? (doc.makeArea == .fabrication ? "Follow the CNC steps above; project tools are in the sections at left." : "Shop settings are saved with the project and can be undone.") : doc.status)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(doc.status).frame(maxWidth:.infinity,alignment:.leading)
                Menu("Other exports") {
                    Section("Cut list") {
                        Button("Copy CSV") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(CutList.csv(rows,metric:doc.metric),forType:.string);doc.status = "Copied cut list CSV." }.disabled(rows.isEmpty)
                        Button("Save CSV…") { saveCSV(rows) }.disabled(rows.isEmpty)
                    }
                    Section("Geometry & drawings") {
                        Button("Single DXF…") { doc.exportFlat(svg:false) }
                        Button("SVG…") { doc.exportFlat(svg:true) }
                        Button("Shop drawings PDF…") { doc.exportDrawings() }
                        Button("STL…") { doc.export3D(format:"stl-mm") }
                    }.disabled(doc.parts.isEmpty || doc.workspaceInspectionOnly)
                }.fixedSize()
                if let preflight {
                    if !preflight.warnings.isEmpty { Toggle("Warnings reviewed",isOn:$warningsReviewed).font(.caption).fixedSize() }
                    Button("Export VCarve Job…") { doc.exportVCarveJob() }.buttonStyle(.borderedProminent)
                        .disabled(!preflight.canExport || doc.workspaceInspectionOnly || (!preflight.warnings.isEmpty && !warningsReviewed))
                        .help(!preflight.hasCutter ? "Choose a stock and cutter setup in Prepare job." : (preflight.errors.first ?? "Export the prepared CNC job"))
                } else {
                    Button("Prepare CNC job") { MakeRoute.prepare.select(doc) }.buttonStyle(.borderedProminent)
                }
            }.padding(16)
        }.frame(width:1060,height:790).background(Color(nsColor:.windowBackgroundColor))
        .onChange(of:doc.project) { _,_ in warningsReviewed = false }
        .onChange(of:doc.cncPartIDs) { _,_ in warningsReviewed = false }
        .onAppear { expandedSections.insert(route.section) }
        .onChange(of:route) { _,newRoute in expandedSections.insert(newRoute.section) }
    }
    private var makeSidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach(MakeSection.allCases,id:\.self) { section in
                        if section == .cnc {
                            VStack(alignment:.leading,spacing:4) {
                                Text(section.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal,10)
                                makeLinks(in:section)
                            }
                        } else {
                            DisclosureGroup(isExpanded:Binding(get:{expandedSections.contains(section)},set:{ value in
                                if value { expandedSections.insert(section) } else { expandedSections.remove(section) }
                            })) {
                                makeLinks(in:section)
                            } label: {
                                Text(section.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }.padding(.horizontal,10)
                        }
                    }
                }
            }
            if doc.cncPartIDs != nil { Text("Selected parts only").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor).padding(10) }
        }.padding(10).frame(width:205).frame(maxHeight:.infinity).background(Color(nsColor:.controlBackgroundColor).opacity(0.4))
    }
    private func makeLinks(in section: MakeSection) -> some View {
        ForEach(MakeRoute.allCases.filter { $0.section == section }) { item in
            Button { item.select(doc) } label: {
                Label(item.title,systemImage:item.symbol).font(.callout).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,10).padding(.vertical,7)
                    .background(route == item ? Color.accentColor.opacity(0.14) : .clear,in:RoundedRectangle(cornerRadius:8))
            }.buttonStyle(.plain).accessibilityAddTraits(route == item ? .isSelected : [])
        }
    }
    @ViewBuilder private func fabricationContent(_ rows: [CutRow]) -> some View {
        switch page {
        case .cutList: cutList(rows)
        case .layout:
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    GroupBox("Sheet stock") {
                        HStack(spacing:16) {
                            DimField(label:"Length",value:$doc.sheetLength,metric:doc.metric,minimum:1/32)
                            DimField(label:"Width",value:$doc.sheetWidth,metric:doc.metric,minimum:1/32)
                            DimField(label:"Part spacing",value:$doc.nestGap,metric:doc.metric,minimum:0)
                        }.padding(8)
                    }
                    Button("Use measured offcuts and review material costs…") { MakeRoute.offcuts.select(doc) }
                    CNCPreview(doc:doc)
                }
            }
        case .review: MachiningReviewPanel(doc:doc,forCNCJob:true)
        case .assembly: AssemblyStepsEditor(doc:doc)
        case .job: CNCJobGuide(doc:doc)
        case .handoff: VCarveHandoffView(doc:doc)
        }
    }
    @ViewBuilder private var shopContent: some View {
        switch ShopPage(rawValue:doc.shopTab) ?? .checks {
        case .checks:AssemblyReviewPanel(doc:doc)
        case .relationships:AssemblyRelationsPanel(doc:doc)
        case .hardware:HardwareTemplatesPanel(doc:doc)
        case .materials:ShopMaterialsPanel(doc:doc)
        case .sheets:SheetInventoryPanel(doc:doc)
        case .delivery:ShopDeliveryPanel(doc:doc)
        case .buy:BuyListView(doc:doc)
        }
    }
    private func cutList(_ rows: [CutRow]) -> some View {
        let matches = rows.filter { PartSearch.matches(search,in:($0.labels+$0.names+[$0.species.rawValue,$0.machining]).joined(separator:" ")) }
        return VStack(alignment:.leading,spacing:12) {
            HStack {
                TextField("Find parts, material, or machining",text:$search).textFieldStyle(.roundedBorder).accessibilityLabel("Search cut list")
                Text("\(rows.reduce(0) { $0+$1.qty }) parts").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            Table(matches,selection:$selectedRows) {
                TableColumn("Qty") { Text("\($0.qty)").monospacedDigit() }.width(32)
                TableColumn("Material") { Text($0.species.rawValue) }.width(80)
                TableColumn("Thickness") { Text(doc.fmt($0.t)) }.width(70)
                TableColumn("Width") { Text(doc.fmt($0.w)) }.width(65)
                TableColumn("Length") { Text(doc.fmt($0.l)) }.width(65)
                TableColumn("Parts / machining") { row in
                    VStack(alignment:.leading,spacing:3) {
                        Text(zip(row.labels,row.names).map { $0+" "+$1 }.joined(separator:", ")).lineLimit(2)
                        if !row.machining.isEmpty { Text(row.machining).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.padding(.vertical,4)
                }
            }
            .contextMenu(forSelectionType:String.self) { ids in
                Button("Select Parts in Model") { reveal(rows.filter { ids.contains($0.id) },isolate:false) }.disabled(ids.isEmpty)
                Button("Isolate Parts in Model") { reveal(rows.filter { ids.contains($0.id) },isolate:true) }.disabled(ids.isEmpty)
                Button("Copy Selected Rows") {
                    NSPasteboard.general.clearContents();NSPasteboard.general.setString(CutList.csv(rows.filter { ids.contains($0.id) },metric:doc.metric),forType:.string)
                }.disabled(ids.isEmpty)
            }
            if matches.isEmpty { Text(rows.isEmpty ? "Add stock to start your cut list." : "No matching rows. Try a part ID, name, or material.").foregroundStyle(.secondary) }
            HStack(spacing:20) {
                Text(String(format:"Solid lumber: %.2f board feet",rows.filter { !$0.species.isSheet }.reduce(0) { $0+$1.boardFeet }))
                Text(String(format:"Sheet goods: %.1f sq ft",rows.filter { $0.species.isSheet }.reduce(0) { $0+$1.sqFeet }))
            }.font(.caption).foregroundStyle(.secondary)
            Text("Blank dimensions include tenons. Right-click rows to find their parts in the model or copy them.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func reveal(_ rows: [CutRow],isolate: Bool) {
        let ids = rows.flatMap(\.partIDs)
        guard let first = ids.first else { return }
        doc.select(first)
        for id in ids.dropFirst() { doc.select(id,extending:true) }
        doc.isolateSelection = isolate;doc.showCutList = false
    }
    private func saveCSV(_ rows: [CutRow]) {
        let panel = NSSavePanel();panel.allowedContentTypes = [.commaSeparatedText];panel.nameFieldStringValue = "\(doc.fileName) cut list.csv"
        if panel.runModal() == .OK,let url = panel.url {
            do { try CutList.csv(rows,metric:doc.metric).write(to:url,atomically:true,encoding:.utf8);doc.status = "Saved cut list." }
            catch { doc.status = "CSV save failed: \(error.localizedDescription)" }
        }
    }
}
