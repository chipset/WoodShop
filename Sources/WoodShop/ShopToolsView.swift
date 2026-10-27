import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ShopPage: Int,CaseIterable,Identifiable {
    case checks,relationships,hardware,materials,sheets,delivery
    var id: Int { rawValue }
    var title: String {
        switch self { case .checks:return "Assembly checks";case .relationships:return "Relationships";case .hardware:return "Hardware";case .materials:return "Materials & cost";case .sheets:return "Sheets & offcuts";case .delivery:return "Documents & recovery" }
    }
    var symbol: String {
        switch self { case .checks:return "checkmark.shield";case .relationships:return "point.3.connected.trianglepath.dotted";case .hardware:return "screwdriver";case .materials:return "square.stack.3d.up";case .sheets:return "square.grid.2x2";case .delivery:return "doc.text" }
    }
}

struct AssemblyReviewPanel: View {
    @ObservedObject var doc: Document
    @State private var clearance = 1.0/16
    @State private var issues: [AssemblyIssue] = []
    @State private var message = "Run checks after positioning the parts. Intended contact is allowed; real solid intersections are reported."
    @State private var busy = false
    @State private var worker: Task<[AssemblyIssue],Never>?
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Check the assembly before cutting").font(.headline)
            HStack {
                DimField(label:"Minimum clearance",value:$clearance,metric:doc.metric,minimum:0).frame(width:280)
                Button("Check all woodworking parts") { run() }.disabled(busy || doc.parts.isEmpty)
                Button("Compare selected hole axes") {
                    let parts = doc.parts.filter { doc.selectedIDs.contains($0.id) }
                    guard parts.count == 2,parts.allSatisfy({ $0.machiningOperations.contains { $0.kind == "Drill" && $0.suppressed != true } }) else { message = "Select two drilled parts to compare their hole axes.";return }
                    issues = AssemblyReview.holeAlignment(parts,metric:doc.metric);message = "Compared hole axes on the two selected parts. This checks alignment, not the hardware’s installation requirements."
                }.disabled(doc.selectedIDs.count != 2 || busy)
                if busy { ProgressView().controlSize(.small);Button("Cancel") { worker?.cancel();busy = false;message = "Check cancelled." } }
            }
            Text(message).font(.callout).foregroundStyle(.secondary)
            List(issues) { issue in
                HStack(alignment:.top,spacing:10) {
                    Image(systemName:issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill").foregroundStyle(issue.severity == .error ? Color.red : .orange)
                    Text(issue.message).frame(maxWidth:.infinity,alignment:.leading)
                    Button("Inspect parts") { doc.selection = issue.parts.first;doc.selectedIDs = Set(issue.parts);doc.isolateSelection = true;doc.showCutList = false }
                }.padding(.vertical,7)
            }
            if !issues.isEmpty { Button("Copy check report") { copyText(issues.map(\.message).joined(separator:"\n"));doc.status = "Copied assembly check report." } }
        }.padding(16).onDisappear { worker?.cancel() }
    }
    private func run() {
        let snapshot = doc.project,limit = clearance
        busy = true;message = "Checking actual machined solids. You can cancel this check."
        let task = Task.detached(priority:.userInitiated) { AssemblyReview.issues(snapshot,minimumClearance:limit,cancelled:{Task.isCancelled}) }
        worker = task
        Task { @MainActor in
            let result = await task.value
            guard !task.isCancelled else { return }
            busy = false
            guard snapshot == doc.project else { message = "The design changed. Run the check again.";return }
            issues = result;message = "Check complete: \(result.filter { $0.severity == .error }.count) intersections and \(result.filter { $0.severity == .warning }.count) clearance warnings. Reference hardware is excluded."
        }
    }
}

struct AssemblyRelationsPanel: View {
    @ObservedObject var doc: Document
    @State private var source: UUID?
    @State private var target: UUID?
    @State private var axis = 0
    @State private var sourceAnchor = AssemblyAnchor.maximum
    @State private var targetAnchor = AssemblyAnchor.minimum
    @State private var offset = 0.0
    @State private var expression = ""
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Keep parts aligned as the design changes").font(.headline)
            Text("Choose a reference and a dependent part. Flush edges use zero offset; centering uses Center on both parts. An offset can follow a named parameter.").foregroundStyle(.secondary)
            HStack {
                partPicker("Reference",selection:$source)
                partPicker("Dependent",selection:$target)
            }
            AxisPicker(title:"World axis",value:$axis)
            HStack {
                Picker("Reference anchor",selection:$sourceAnchor) { ForEach(AssemblyAnchor.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Dependent anchor",selection:$targetAnchor) { ForEach(AssemblyAnchor.allCases) { Text($0.rawValue).tag($0) } }
            }
            HStack {
                DimField(label:"Offset / spacing",value:$offset,metric:doc.metric)
                TextField("Optional offset expression, e.g. thickness",text:$expression).textFieldStyle(.roundedBorder)
                Button("Keep this relationship") {
                    if let source,let target { _ = doc.setAssemblyRelation(AssemblyRelation(source:source,target:target,axis:axis,sourceAnchor:sourceAnchor,targetAnchor:targetAnchor,offset:offset,expression:expression.trimmingCharacters(in:.whitespaces).isEmpty ? nil : expression,metricLiterals:doc.metric)) }
                }.disabled(source == nil || target == nil || source == target || doc.workspaceInspectionOnly)
            }
            Divider()
            List(doc.studio.relations ?? []) { r in
                HStack {
                    Text((doc.part(r.target)?.name ?? "Missing part")+" follows "+(doc.part(r.source)?.name ?? "Missing reference")+" · "+FaceRef.axisNames[r.axis])
                    Spacer();Text(r.expression ?? doc.fmt(r.offset)).foregroundStyle(.secondary)
                    Button("Select") { doc.select(r.target);doc.showInspector = true }
                    Button("Remove") { doc.transaction { doc.studio.relations?.removeAll { $0.id == r.id } } }
                }
            }
            Text("Each dependent axis has one placement rule. Cycles and conflicts with driving position expressions or automatic shelf seating are rejected without changing the model.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).onAppear {
            source = doc.selection;target = doc.parts.first { doc.selectedIDs.contains($0.id) && $0.id != source }?.id
        }
    }
    private func partPicker(_ title: String,selection: Binding<UUID?>) -> some View {
        Picker(title,selection:selection) { Text("Choose part").tag(nil as UUID?);ForEach(doc.parts) { Text(ShopIdentity.label($0)+" "+$0.name).tag(Optional($0.id)) } }
    }
}

struct HardwareTemplatesPanel: View {
    @ObservedObject var doc: Document
    @State private var draft = HardwareTemplate()
    private var templates: [HardwareTemplate] { doc.hardwareTemplates+HardwareTemplate.examples.filter { example in !doc.hardwareTemplates.contains { $0.id == example.id } } }
    var body: some View {
        HStack(alignment:.top,spacing:20) {
            VStack(alignment:.leading,spacing:12) {
                Text("Reusable hardware patterns").font(.headline)
                List(templates) { template in Button(template.name) { draft = template;draft.pattern.placement = .fixed }.buttonStyle(.plain) }
                Button("New template") { draft = HardwareTemplate();draft.pattern.placement = .fixed }
                Button("Duplicate template") { draft.id = UUID();draft.name += " copy" }
            }.frame(width:240)
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    TextField("Template name",text:$draft.name).textFieldStyle(.roundedBorder)
                    if let maker = draft.manufacturer,let partNumber = draft.partNumber {
                        VStack(alignment:.leading,spacing:5) {
                            Text("\(maker) · \(partNumber)").font(.subheadline.bold())
                            if let dimensions = draft.verifiedDimensions { Text("Documented: "+dimensions).font(.caption) }
                            if let source = draft.sourceURL,let url = URL(string:source) { Link("Open manufacturer drawing",destination:url).font(.caption) }
                            Text("Template fields are editable. Confirm the chosen face, reference edge, screws, stock thickness, and current drawing before machining.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Enter the dimensions for your actual hardware. Templates create editable drilling patterns on the selected face; selected component instances become unique.").font(.callout).foregroundStyle(.secondary)
                    HStack { DimField(label:"Hole diameter",value:$draft.pattern.diameter,metric:doc.metric,minimum:0.001);DimField(label:"Depth",value:$draft.pattern.depth,metric:doc.metric,minimum:0.001) }
                    Toggle("Through stock",isOn:$draft.pattern.through)
                    HStack { Stepper("Columns: \(draft.pattern.columns)",value:$draft.pattern.columns,in:1...100);Stepper("Rows: \(draft.pattern.rows)",value:$draft.pattern.rows,in:1...100) }
                    HStack { DimField(label:"First hole U",value:$draft.pattern.origin.x,metric:doc.metric);DimField(label:"First hole V",value:$draft.pattern.origin.y,metric:doc.metric) }
                    HStack { DimField(label:"Pitch U",value:$draft.pattern.pitch.x,metric:doc.metric,minimum:0);DimField(label:"Pitch V",value:$draft.pattern.pitch.y,metric:doc.metric,minimum:0) }
                    Stepper("Hardware quantity per use: \(draft.quantityPerUse)",value:$draft.quantityPerUse,in:1...1000)
                    HStack { Text("Unit cost");TextField("Unit cost",value:$draft.unitCost,format:.number).textFieldStyle(.roundedBorder) }
                    TextField("Installation / purchasing notes",text:$draft.notes,axis:.vertical).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save for future projects") {
                            do { try draft.validate();var list = doc.hardwareTemplates;list.removeAll { $0.id == draft.id };list.append(draft);try doc.hardwareTemplateStore.save(list);doc.hardwareTemplates = list;doc.status = "Saved reusable hardware template." }
                            catch { doc.status = error.localizedDescription }
                        }
                        Spacer();Button("Apply to selected parts") { _ = doc.applyHardwareTemplate(draft,parts:doc.selectedIDs) }.buttonStyle(.borderedProminent).disabled(doc.selectedIDs.isEmpty || doc.workspaceInspectionOnly)
                    }
                }.padding(8)
            }
        }.padding(16).onAppear { draft = templates.first ?? HardwareTemplate();draft.pattern.placement = .fixed }
    }
}

struct ShopMaterialsPanel: View {
    @ObservedObject var doc: Document
    @State private var draft = PartShopData()
    @State private var species = Species.plywood
    @State private var squareRate = 0.0
    @State private var boardRate = 0.0
    @State private var bandRate = 0.0
    @State private var waste = 0.15
    var body: some View {
        VStack(spacing:0) {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("Core dimensions, finished dimensions, and purchasing").font(.headline)
                Text("Part dimensions describe the wood core. Edge banding adds to the finished size. Rough allowance adds to purchasing sizes; it does not change CNC cutting outlines.").foregroundStyle(.secondary)
                if let part = doc.selectedPart {
                    GroupBox(ShopIdentity.label(part)+" · "+part.name) {
                        VStack(alignment:.leading,spacing:12) {
                            HStack { ForEach(BandEdge.allCases) { edge in Toggle(edge.rawValue,isOn:Binding(get:{draft.bandedEdges.contains(edge)},set:{ value in draft.bandedEdges.removeAll { $0 == edge };if value { draft.bandedEdges.append(edge) } })) } }
                            Text("Ends are across the grain; edges run along it.").font(.caption).foregroundStyle(.secondary)
                            HStack { DimField(label:"Band thickness",value:$draft.bandThickness,metric:doc.metric,minimum:0);DimField(label:"Rough allowance per side",value:$draft.roughAllowance,metric:doc.metric,minimum:0) }
                            TextField("Grain matching group, e.g. Upper cabinet doors",text:$draft.grainMatchGroup).textFieldStyle(.roundedBorder)
                            HStack {
                                Toggle("Ordered grain run",isOn:Binding(get:{draft.grainMatchOrder != nil},set:{draft.grainMatchOrder = $0 ? (draft.grainMatchOrder ?? 1) : nil}))
                                if draft.grainMatchOrder != nil { Stepper("Position \(draft.grainMatchOrder ?? 1)",value:Binding(get:{draft.grainMatchOrder ?? 1},set:{draft.grainMatchOrder = $0}),in:1...10000) }
                            }
                            Text("Panels in one group stay together on one sheet, with grain along the sheet length. Position sets their cross-grain sequence. Assign one position per panel; a group that cannot fit one sheet is flagged for revision.").font(.caption).foregroundStyle(.secondary)
                            Text("Finished size: "+[draft.finished(part)[part.materialAxes.l],draft.finished(part)[part.materialAxes.w],part.size[part.materialAxes.t]].map { doc.fmt($0) }.joined(separator:" × ")).font(.callout)
                            Button("Apply to selected parts") { _ = doc.transaction {
                                try draft.validate()
                                var position = draft.grainMatchOrder
                                for i in doc.parts.indices where doc.selectedIDs.contains(doc.parts[i].id) {
                                    var data = draft;data.grainMatchOrder = position;doc.parts[i].shop = data
                                    if position != nil { position! += 1 }
                                }
                            } }.disabled(doc.workspaceInspectionOnly)
                        }.padding(8)
                    }
                } else { Text("Select a part to assign edge banding and rough-stock allowance.").foregroundStyle(.secondary) }
                GroupBox("Your material prices") {
                    VStack(alignment:.leading,spacing:12) {
                        Picker("Material",selection:$species) { ForEach(Species.allCases) { Text($0.rawValue).tag($0) } }
                        HStack {
                            VStack(alignment:.leading) { Text("Sheet cost per square foot").font(.caption);TextField("Sheet cost",value:$squareRate,format:.number) }
                            VStack(alignment:.leading) { Text("Lumber cost per board foot").font(.caption);TextField("Lumber cost",value:$boardRate,format:.number) }
                        }.textFieldStyle(.roundedBorder)
                        VStack(alignment:.leading) { Text("Banding cost per linear foot").font(.caption);TextField("Banding cost",value:$bandRate,format:.number).textFieldStyle(.roundedBorder) }
                        Button("Save material rate") { doc.transaction { var rates = doc.studio.materialRates ?? [];rates.removeAll { $0.species == species };rates.append(MaterialRate(species:species,perSquareFoot:squareRate,perBoardFoot:boardRate,bandPerFoot:bandRate));doc.studio.materialRates = rates } }
                        Text("Use one currency throughout the project. Enter your own prices; a zero rate leaves that material unpriced.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Lumber allowance") {
                    HStack { Text("Waste allowance");Slider(value:$waste,in:0...1,step:0.01);Text(waste.formatted(.percent)).monospacedDigit().frame(width:50);Button("Save") { doc.transaction { doc.studio.lumberWaste = waste } } }.padding(8)
                }
                let estimate = ShopPlanning.estimate(doc.project,layout:CNCAnalysis.layout(doc.project))
                Text(String(format:"Estimated lumber %.2f · Sheet stock %.2f · Banding %.2f · Hardware %.2f · Total %.2f",estimate.lumber,estimate.sheets,estimate.banding,estimate.hardware,estimate.lumber+estimate.sheets+estimate.banding+estimate.hardware)).font(.headline)
                Text("Banding length: "+doc.fmt(estimate.bandLength)+" before waste. Sheet cost uses the actual nested sheets / offcuts. Lumber includes a 15% waste allowance unless changed in the project.").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
        Divider()
        HStack {
            Button("Shop schedule CSV…") { saveShopText(ShopPlanning.schedule(doc.project),name:doc.fileName+" shop schedule.csv",type:.commaSeparatedText,doc:doc) }
            Button("Grain match map CSV…") { saveShopText(ShopPlanning.grainMatchMap(doc.project,layout:CNCAnalysis.layout(doc.project)),name:doc.fileName+" grain match map.csv",type:.commaSeparatedText,doc:doc) }
            Button("Hardware schedule CSV…") { saveShopText(ShopPlanning.hardwareSchedule(doc.project),name:doc.fileName+" hardware.csv",type:.commaSeparatedText,doc:doc) }
            Spacer()
        }.padding(12)
        }.onAppear { draft = doc.selectedPart?.shop ?? PartShopData();waste = doc.studio.lumberWaste ?? 0.15;loadRate() }.onChange(of:doc.selection) { _,_ in draft = doc.selectedPart?.shop ?? PartShopData() }.onChange(of:species) { _,_ in loadRate() }
    }
    private func loadRate() { let rate = doc.studio.materialRates?.first { $0.species == species };squareRate = rate?.perSquareFoot ?? 0;boardRate = rate?.perBoardFoot ?? 0;bandRate = rate?.bandPerFoot ?? 0 }
}

struct SheetInventoryPanel: View {
    @ObservedObject var doc: Document
    @State private var draft = SheetStock()
    @State private var cost = 0.0
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Use measured offcuts before opening new sheets").font(.headline)
            Text("Length follows grain. Part rotation remains opt-in. Enabled offcuts must fit within the current default sheet dimensions; larger inventory stays saved for another setup.").foregroundStyle(.secondary)
            Toggle("Use enabled offcuts for CNC nesting",isOn:Binding(get:{doc.studio.useOffcuts == true},set:{ value in doc.transaction { doc.studio.useOffcuts = value } }))
            GroupBox("Add measured offcut") {
                VStack(spacing:12) {
                    HStack { TextField("Stock label",text:$draft.name).textFieldStyle(.roundedBorder);Picker("Material",selection:$draft.species) { ForEach(Species.allCases) { Text($0.rawValue).tag($0) } } }
                    HStack { DimField(label:"Length",value:$draft.length,metric:doc.metric,minimum:1/32);DimField(label:"Width",value:$draft.width,metric:doc.metric,minimum:1/32);DimField(label:"Thickness",value:$draft.thickness,metric:doc.metric,minimum:1/32) }
                    HStack { Text("Purchase cost (0 uses material rate)").font(.caption);TextField("Purchase cost",value:$cost,format:.number).textFieldStyle(.roundedBorder);Button("Add offcut") { if doc.transaction({ var stock = draft;stock.id = UUID();stock.cost = cost == 0 ? nil : cost;try stock.validate();doc.studio.offcuts = (doc.studio.offcuts ?? [])+[stock] }) { doc.status = "Added measured offcut. Enable offcut nesting to use it." } } }
                }.padding(8)
            }
            List(doc.studio.offcuts ?? []) { stock in
                HStack {
                    Toggle(stock.name,isOn:Binding(get:{stock.enabled},set:{ value in doc.transaction { if let i = doc.studio.offcuts?.firstIndex(where: { $0.id == stock.id }) { doc.studio.offcuts![i].enabled = value } } }))
                    Spacer();Text(stock.species.rawValue+" · "+[stock.length,stock.width,stock.thickness].map { doc.fmt($0) }.joined(separator:" × ")).foregroundStyle(.secondary)
                    Button("Remove") { doc.transaction { doc.studio.offcuts?.removeAll { $0.id == stock.id } } }
                }
            }
            if (doc.studio.offcuts ?? []).isEmpty { Text("No measured offcuts yet. Add one above to use it in your next nesting preview.").font(.callout).foregroundStyle(.secondary) }
            let result = CNCAnalysis.layout(doc.cncProject)
            Text("\(result.placed.count) \(result.placed.count == 1 ? "part" : "parts") · \(result.sheets.count) \(result.sheets.count == 1 ? "sheet" : "sheets") · \(Int(result.utilization*100))% outline utilization").font(.headline)
            if !result.sheets.isEmpty { Text(result.sheets.indices.map { index in
                let stock = result.stock(at:index)
                return "Sheet \(index+1): \(stock?.name ?? "Full sheet") · \(result.placed.filter { $0.sheet == index }.count) parts · \(stock.map { doc.fmt($0.length)+" × "+doc.fmt($0.width) } ?? "")"
            }.joined(separator:"\n")).font(.caption).foregroundStyle(.secondary) }
            Text("Nesting compares two free-rectangle strategies and retains the older shelf layout if it uses fewer full sheets. Saved offcuts are not deleted by an export; mark used pieces unavailable yourself.").font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}

struct ShopDeliveryPanel: View {
    @ObservedObject var doc: Document
    @State private var versions: [ProjectBackupInfo] = []
    @State private var audit = ""
    @State private var performance = ""
    @State private var measuring = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("Shop documents & checked exports").font(.headline)
                HStack { Button("Exploded assembly PDF…") { doc.exportExplodedGuide() };Button("Shop drawings PDF…") { doc.exportDrawings() };Button("Labels PDF…") { doc.exportShopLabels() } }
                HStack {
                    Button("Build VCarve validation package…") { doc.exportVCarveValidation() }
                    Button("Copy usability test form") { copyText(ShopValidation.usabilityChecklist);doc.status = "Copied the usability test form." }
                    Button("Save test form…") { saveShopText(ShopValidation.usabilityChecklist,name:"WoodShop usability session.txt",type:.plainText,doc:doc) }
                }
                Text("The validation package contains representative pockets, islands, curved grooves, bottom machining, and an edge fixture. It includes expected units and import checks for a person running VCarve.").font(.callout).foregroundStyle(.secondary)
                Divider()
                Text("Large-project performance").font(.headline)
                Text("Measure validation, regeneration, CNC flattening, and sheet nesting on this Mac. Working targets are 2, 5, 3, and 10 seconds per 500 parts; results report the actual elapsed time and any failed operation.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(measuring ? "Measuring…" : "Benchmark current project") {
                        measuring = true;performance = "Running the project audit…"
                        let project = doc.cncProject
                        DispatchQueue.global(qos:.userInitiated).async {
                            let result = PerformanceAudit.run(project).summary
                            DispatchQueue.main.async { performance = result;measuring = false }
                        }
                    }.disabled(measuring)
                    Button("Copy report") { copyText(performance) }.disabled(performance.isEmpty || measuring)
                    Button("Save report…") { saveShopText(performance,name:"WoodShop performance report.txt",type:.plainText,doc:doc) }.disabled(performance.isEmpty || measuring)
                }
                if !performance.isEmpty { Text(performance).font(.system(.caption,design:.monospaced)).textSelection(.enabled) }
                Divider()
                Text("Project recovery").font(.headline)
                Text("Each save validates the incoming file and keeps up to three readable backups. Restoring here changes the open design with Undo available; Save writes it to the current project.").foregroundStyle(.secondary)
                Button("Inspect saved and recovery copies") {
                    versions = ProjectBackupInfo.inspect(doc:doc);audit = versions.isEmpty ? "Save this project or make an unsaved edit to create recovery copies." : "Inspected \(versions.count) files."
                }
                Text(audit).font(.caption).foregroundStyle(.secondary)
                ForEach(versions) { info in
                    HStack {
                        Image(systemName:info.project == nil ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(info.project == nil ? Color.orange : .green)
                        VStack(alignment:.leading) { Text(info.url.lastPathComponent).font(.callout);Text(info.summary).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Restore copy") { if let project = info.project { if doc.transaction({ doc.restore(project) }) { doc.status = "Restored backup. Undo returns to the previous open design." } } }.disabled(info.project == nil)
                    }.padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                }
            }.padding(16)
        }
    }
}

private func copyText(_ text: String) { NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string) }
private func saveShopText(_ text: String,name: String,type: UTType,doc: Document) {
    let panel = NSSavePanel();panel.allowedContentTypes = [type];panel.nameFieldStringValue = name
    guard panel.runModal() == .OK,let url = panel.url else { return }
    do { try text.write(to:url,atomically:true,encoding:.utf8);doc.status = "Saved "+url.lastPathComponent }
    catch { doc.status = error.localizedDescription }
}
