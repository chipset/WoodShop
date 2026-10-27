import SwiftUI

struct CNCPreflight {
    var errors: [String] = []
    var warnings: [String] = []
    var sheets = 0
    var parts = 0
    var hasCutter = false
    var canExport: Bool { errors.isEmpty && parts > 0 && hasCutter }
    init(project: Project) {
        parts = project.parts.filter { $0.hardware != true }.count
        hasCutter = project.studio?.setupProfile?.defaultTool != nil
        do { try ModelValidation.validate(project) } catch { errors.append(error.localizedDescription) }
        if parts == 0 { errors.append("Choose at least one woodworking part.") }
        if let message = ModelValidation.nesting(sheetL:project.sheetLength,sheetW:project.sheetWidth,gap:project.nestGap,registration:project.studio?.registration ?? Registration()) { errors.append(message) }
        let issues = CNCAnalysis.review(project)
        errors += issues.filter { $0.severity == .error }.map(\.message)
        warnings = issues.filter { $0.severity == .warning }.map(\.message)
        if errors.isEmpty,parts > 0 {
            let layout = CNCAnalysis.layout(project)
            sheets = layout.sheets.count
            if !layout.oversize.isEmpty { errors.append("Parts exceed the sheet size: "+layout.oversize.joined(separator:", ")) }
        }
    }
}

struct CNCJobGuide: View {
    @ObservedObject var doc: Document
    @State private var setups = false
    var body: some View {
        let report = CNCPreflight(project:doc.cncProject)
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                step("1",title:"Choose parts",detail:doc.cncPartIDs == nil ? "All woodworking parts · \(report.parts) parts" : "Pinned selection · \(report.parts) parts",complete:report.parts > 0) {
                    HStack {
                        Button("Use all parts") { doc.cncPartIDs = nil }
                        Button("Use current selection") { doc.cncPartIDs = doc.selectedIDs }.disabled(doc.selectedIDs.isEmpty)
                    }
                }
                step("2",title:"Choose stock & cutter",detail:doc.studio.setupProfile?.name ?? "Choose a setup to check the actual cutter diameter and reach.",complete:report.hasCutter) {
                    HStack {
                        Button("Choose / edit setup…") { setups = true }
                        if let tool = doc.studio.setupProfile?.defaultTool { Text(tool.name+" · "+doc.fmt(tool.diameter)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                step("3",title:"Review sheet layout",detail:"\(report.sheets) sheets · \(doc.fmt(doc.sheetLength)) × \(doc.fmt(doc.sheetWidth)) · \(doc.metric ? "millimeters" : "inches")",complete:report.sheets > 0 && report.errors.isEmpty) {
                    Button("Inspect sheets & machining faces") { doc.fabricationTab = 1 }
                }
                step("4",title:"Review machining",detail:"\(report.errors.count) errors · \(report.warnings.count) warnings",complete:report.errors.isEmpty && report.warnings.isEmpty) {
                    Button("Inspect issues & edit features") { doc.fabricationTab = 2;doc.showReviewHighlights = true }
                }
                if let first = report.errors.first { Label(first,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                step("5",title:"Export & open in VCarve",detail:"Import the matching TOP DXF using the saved units and origin. A visual setup sheet accompanies every machining file.",complete:false) {
                    Button("View VCarve handoff instructions") { doc.fabricationTab = 5 }
                }
            }
        }.sheet(isPresented:$setups) { SetupProfilesPanel(doc:doc) }
    }
    private func step<Content: View>(_ number: String,title: String,detail: String,complete: Bool,@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment:.top,spacing:12) {
            ZStack {
                Circle().fill(complete ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.1)).frame(width:30,height:30)
                if complete { Image(systemName:"checkmark").foregroundStyle(.green) } else { Text(number).foregroundStyle(Color.accentColor) }
            }
            VStack(alignment:.leading,spacing:7) { Text(title).font(.headline);Text(detail).font(.callout).foregroundStyle(.secondary);content() }
            Spacer(minLength:0)
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
    }
}

struct VCarveHandoffView: View {
    @ObservedObject var doc: Document
    @State private var showLayers = false
    @State private var showOtherFaces = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                GroupBox("Match the job setup") {
                    VStack(alignment:.leading,spacing:8) {
                        LabeledContent("Import units",value:doc.metric ? "Millimeters" : "Inches")
                        LabeledContent("Stock size",value:doc.fmt(doc.sheetLength)+" × "+doc.fmt(doc.sheetWidth))
                        LabeledContent("XY origin",value:"Bottom-left corner · X0 Y0")
                        LabeledContent("Stock thickness",value:"Use the material / thickness in each sheet filename")
                        LabeledContent("Cutter",value:doc.studio.setupProfile?.defaultTool?.name ?? "Choose a setup first")
                        if let name = doc.studio.setupProfile?.vcarveTemplate,!name.isEmpty { LabeledContent("Toolpath template",value:name) }
                    }.font(.callout).padding(8)
                }
                Text("1. Import each numbered sheet’s TOP DXF. Match its units, stock, origin, and setup PDF.")
                Text("2. Create toolpaths from the cutting layers. Set cutters and depths, add hold-down tabs, then simulate in VCarve.")
                Text("3. If a sheet has BOTTOM or SIDE files, follow their separate setup PDFs. Cut the final outside profile after both faces are finished.")
                Text("4. Review the simulation and post for your machine. VCarve applies cutter compensation and generates machine code.")
                DisclosureGroup("Layer-by-layer reference",isExpanded:$showLayers) {
                    VStack(alignment:.leading,spacing:10) {
                        ForEach(VCarveLayerGuide.rows,id:\.0) { row in
                            HStack(alignment:.top,spacing:14) { Text(row.0).font(.caption.monospaced()).frame(width:160,alignment:.leading);Text(row.1).font(.callout).foregroundStyle(.secondary) }
                        }
                    }.padding(.top,8)
                }
                DisclosureGroup("Bottom and side setup details",isExpanded:$showOtherFaces) {
                    VStack(alignment:.leading,spacing:10) {
                        Text("BOTTOM: Flip about the sheet length (X) axis. Keep X fixed; Y is already mirrored. Use registration pins when configured. Do not mirror the vectors again.")
                        Text("SIDE: Use a separate fixture. The filename and setup PDF identify face normal and local U/V axes. The origin is the minimum U/V corner of that stock face.")
                    }.padding(.top,8)
                }
            }.font(.callout).textSelection(.enabled)
        }
    }
}

enum VCarveLayerGuide {
    static let rows: [(String,String)] = [
        ("OUTLINE","Outside profile. Final through cut; add tabs."),
        ("POCKET_<depth>","Pocket to the depth and units in the layer name."),
        ("…DRILL / …COUNTERBORE","Layers containing DRILL or COUNTERBORE identify holes or recesses. The suffix gives cutting depth and units."),
        ("…COUNTERSINK / …DOVETAIL","Use the appropriate form tool and inspect the setup notes."),
        ("CUTOUT_THROUGH","Inside through-cut geometry."),
        ("SHEET / LABELS","Reference only; exclude from cutting toolpaths."),
        ("TENON / REFERENCE_OUTLINE","Shoulder / bottom alignment references; exclude from cutting.")
    ]
}
