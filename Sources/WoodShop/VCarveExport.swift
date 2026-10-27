import AppKit
import UniformTypeIdentifiers

struct VCarvePlacement: Codable {
    var partID: UUID?
    var name: String
    var sheet: Int
    var xInches: Double
    var yInches: Double
    var rotationDegrees: Int
    var negativeFaceUp: Bool
    var label: String? = nil
    var grainMatchGroup: String? = nil
    var grainMatchOrder: Int? = nil
}
struct VCarveJob: Codable {
    var formatVersion = 3
    var sheetStocks: [Int:SheetStock]? = nil
    var vectorUnits: String
    var modelUnits = "inches"
    var stockLengthInches: Double
    var stockWidthInches: Double
    var registration: Registration
    var placements: [VCarvePlacement]
    var parts: [Part]
    var parameters: [DesignParameter]
    var notes: [String]
    var setupProfile: CNCSetupProfile? = nil
    var matingJoints: [MatingJoint]? = nil
}
struct VCarveArtifact { var name: String; var data: Data }
enum VCarveExport {
    static func filename(_ raw: String) -> String {
        raw.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted).joined(separator: "_").prefix(100).description
    }
    static func artifacts(project input: Project) throws -> [VCarveArtifact] {
        let project = ShopIdentity.numbered(input)
        try ModelValidation.validate(project)
        let issues = MachiningReview.issues(project:project)
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else { throw ModelValidation.Failure(message:errors.map(\.message).joined(separator:"\n")) }
        let parts = project.parts.filter { $0.hardware != true }
        guard !parts.isEmpty else { throw ModelValidation.Failure(message: "Add a woodworking part before exporting.") }
        let registration = project.studio?.registration ?? Registration()
        let flats = parts.map(Flatten.flat)
        guard !flats.contains(where: { $0.contours.isEmpty }) else { throw ModelValidation.Failure(message: "A part has no valid cutting outline.") }
        let result = Nesting.nest(flats, sheetL: project.sheetLength, sheetW: project.sheetWidth, gap: project.nestGap, registration: registration,stocks:project.studio?.nestingStocks ?? [])
        guard result.oversize.isEmpty else { throw ModelValidation.Failure(message: "Parts do not fit the stock: " + result.oversize.joined(separator: ", ")) }
        var artifacts: [VCarveArtifact] = []
        for (index, sheet) in result.sheets.enumerated() {
            var placed = result.placed.filter { $0.sheet == index }
            guard !placed.isEmpty else { continue }
            for i in placed.indices { placed[i].x -= sheet.x }
            let stock = result.stock(at:index)
            let local = Nesting.Result(placed: placed, sheets: [(sheet.group, sheet.index, 0)], sheetL:stock?.length ?? result.sheetL,sheetW:stock?.width ?? result.sheetW,oversize:[])
            let setups: [CNCSetup] = placed.contains(where: { $0.part.features.contains { $0.side == .bottom } }) ? [.top, .bottom] : [.top]
            let base = String(format: "Sheet %02d - ", index + 1) + filename(Nesting.groupLabel(sheet.group,metric:project.metric)) + (stock?.name != "Full sheet" && stock != nil ? " - "+filename(stock!.name)+" "+Units.decimal(stock!.length)+"x"+Units.decimal(stock!.width)+"in" : "")
            for setup in setups {
                let primitives = CNCOut.prims(local, metric: project.metric, setup: setup, registration: registration)
                let tag = setup == .top ? "TOP" : "BOTTOM-FLIP-LENGTH-AXIS"
                artifacts.append(VCarveArtifact(name: base + " - " + tag + ".dxf", data: Data(CNCOut.dxf(primitives, metric: project.metric).utf8)))
                artifacts.append(VCarveArtifact(name: base + " - " + tag + ".svg", data: Data(CNCOut.svg(primitives, sheetL:local.sheetL,sheetW:local.sheetW, count: 1, metric: project.metric).utf8)))
                artifacts.append(VCarveArtifact(name:base+" - "+tag+" - Setup.pdf",data:CNCSetupSheet.pdf(name:base+" - "+tag,project:project,layout:local,setup:setup,orientation:setup == .top ? "TOP face up. Import this sheet’s TOP DXF. Keep the stock intact for any second-side machining." : "BOTTOM face up. Flip about the sheet length (X) axis. Keep X fixed; Y is already mirrored. Do not mirror the vectors again. Use the configured registration holes.")))
            }
        }
        // End/edge machining is exported in its own local fixture coordinates, never projected into a top toolpath.
        for (partIndex, part) in parts.enumerated() {
            var groups: [String: (Int, Bool, [Feature])] = [:]
            for cut in part.cuts where !cut.additive && cut.suppressed != true {
                let normal = cut.faceAxis ?? part.materialAxes.t
                guard normal != part.materialAxes.t else { continue }
                let u = (normal + 1) % 3, v = (normal + 2) % 3
                let positive = cut.facePositive ?? true
                let key = "\(normal)-\(positive)"
                var entry = groups[key] ?? (normal, positive, [])
                let polygon = cut.machiningContour(part: part)
                entry.2.append(Feature(kind: cut.kind, side: .top, depth: cut.hi[normal] - cut.lo[normal], rect: (SIMD2(cut.lo[u],cut.lo[v]),SIMD2(cut.hi[u],cut.hi[v])), polygon: polygon))
                groups[key] = entry
            }
            for op in part.machiningOperations where op.axis != part.materialAxes.t && op.suppressed != true {
                let key = "\(op.axis)-\(op.positive)"
                var entry = groups[key] ?? (op.axis, op.positive, [])
                let lo = op.contour.reduce(op.contour[0]) { SIMD2(min($0.x,$1.x),min($0.y,$1.y)) }
                let hi = op.contour.reduce(op.contour[0]) { SIMD2(max($0.x,$1.x),max($0.y,$1.y)) }
                entry.2.append(Feature(kind: op.kind, side: .top, depth: op.depth, rect: (lo,hi), polygon: op.contour,islands:op.islands ?? [])); groups[key] = entry
            }
            for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
                let (a, positive, features) = group, u = (a + 1) % 3, v = (a + 2) % 3
                let outline = [SIMD2<Double>.zero,SIMD2(part.size[u],0),SIMD2(part.size[u],part.size[v]),SIMD2(0,part.size[v])]
                let flat = FlatPart(name: part.name, species: part.species, thickness: part.size[a], width: part.size[v], length: part.size[u], outline: outline, features: features, tenons: [], notes: [])
                let side = Nesting.Result(placed: [Placed(part: flat, x: 0, y: 0, sheet: 0, group: part.name)], sheets: [], sheetL: part.size[u], sheetW: part.size[v], oversize: [])
                let primitives = CNCOut.prims(side, metric: project.metric, setup: .top)
                let name = String(format: "Part %02d - ",partIndex + 1) + ShopIdentity.label(part) + " " + filename(part.name) + " - SIDE " + (positive ? "+" : "-") + FaceRef.axisNames[a] + " U" + FaceRef.axisNames[u] + " V" + FaceRef.axisNames[v] + ".dxf"
                artifacts.append(VCarveArtifact(name: name, data: Data(CNCOut.dxf(primitives, metric: project.metric).utf8)))
                artifacts.append(VCarveArtifact(name:String(name.dropLast(4))+" - Setup.pdf",data:CNCSetupSheet.pdf(name:String(name.dropLast(4)),project:project,layout:side,setup:.top,orientation:"SIDE fixture: \(positive ? "+" : "−")\(FaceRef.axisNames[a]) face up. Horizontal U = \(FaceRef.axisNames[u]); vertical V = \(FaceRef.axisNames[v]). Origin is the minimum U/V corner of this stock face. Use a separate fixture; these vectors are not a top-sheet toolpath.")))
            }
        }
        var notes = flats.flatMap { f in f.notes.map { f.name + ": " + $0 } }
        func length(_ value: Double) -> String { Units.format(value, metric: project.metric) }
        for part in parts {
            for cut in part.cuts where cut.suppressed != true {
                if let relief = cut.relief {
                    notes.append("\(part.name) · \(cut.kind): \(relief.style.rawValue), cutter \(length(relief.diameter)), total fit clearance \(length(cut.allowance ?? 0)).")
                    let a = cut.faceAxis ?? part.materialAxes.t, u = (a + 1) % 3, v = (a + 2) % 3
                    let polygon = cut.machiningContour(part: part)
                    let wall = polygon.reduce(Double.infinity) { min($0,$1.x,$1.y,part.size[u] - $1.x,part.size[v] - $1.y) }
                    if wall < relief.diameter / 4 { notes.append("\(part.name): check thin walls/open edges around the relief before machining.") }
                }
            }
            for op in part.machiningOperations where op.suppressed != true {
                let diameter = op.contour.map(\.x).max()! - op.contour.map(\.x).min()!
                var note = "\(part.name) · \(op.name): face \(op.positive ? "+" : "-")\(FaceRef.axisNames[op.axis]), depth \(length(op.depth)), opening U span \(length(diameter))."
                if op.kind == "Countersink" { note += " Included angle \(Units.decimal(atan(diameter * (1 - op.bottomScale) / (2 * op.depth)) * 360 / .pi))°." }
                notes.append(note)
            }
        }
        let placements = result.placed.map { placed in
            VCarvePlacement(partID: placed.part.sourceID, name: placed.part.name, sheet: placed.sheet + 1,
                xInches: placed.x - result.sheets[placed.sheet].x, yInches: placed.y, rotationDegrees: placed.part.rotationDegrees, negativeFaceUp: placed.part.flippedFace, label:placed.part.shopLabel,grainMatchGroup:placed.part.grainMatchGroup,grainMatchOrder:placed.part.grainMatchOrder)
        }
        var job = VCarveJob(vectorUnits: project.metric ? "millimeters" : "inches", stockLengthInches: project.sheetLength, stockWidthInches: project.sheetWidth,
            registration: registration, placements: placements, parts: parts, parameters: project.studio?.parameters ?? [], notes: notes + issues.map(\.message), setupProfile:project.studio?.setupProfile, matingJoints:project.studio?.matingJoints)
        job.sheetStocks = result.stockRecords
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        artifacts.append(VCarveArtifact(name: "Setup and parameters.json", data: try encoder.encode(job)))
        artifacts.append(VCarveArtifact(name: "Cut list.csv", data: Data(CutList.csv(CutList.rows(parts), metric: project.metric).utf8)))
        artifacts.append(VCarveArtifact(name:"Part labels.pdf",data:ShopDocuments.labels(project:project)))
        artifacts.append(VCarveArtifact(name:"Assembly guide.pdf",data:ShopDocuments.assembly(project:project)))
        artifacts.append(VCarveArtifact(name:"Shop drawings.pdf",data:Drawing.pdf(parts:parts,title:"Shop drawings",metric:project.metric,dimensions:project.studio?.dimensions ?? [])))
        artifacts.append(VCarveArtifact(name:"Exploded assembly.pdf",data:ExplodedGuide.pdf(project:project)))
        artifacts.append(VCarveArtifact(name:"Shop schedule.csv",data:Data(ShopPlanning.schedule(project).utf8)))
        artifacts.append(VCarveArtifact(name:"Grain match map.csv",data:Data(ShopPlanning.grainMatchMap(project,layout:result).utf8)))
        artifacts.append(VCarveArtifact(name:"Hardware schedule.csv",data:Data(ShopPlanning.hardwareSchedule(project).utf8)))
        let instructions = """
        WoodShop → VCarve job
        Vector units: \(project.metric ? "millimeters" : "inches")
        Saved setup: \(project.studio?.setupProfile?.name ?? "Custom")
        VCarve template: \(project.studio?.setupProfile?.vcarveTemplate ?? "")
        \(project.studio?.setupProfile?.notes ?? "")
        Sheet stock: \(Units.format(project.sheetLength,metric:project.metric)) × \(Units.format(project.sheetWidth,metric:project.metric))

        1. Create one VCarve job per numbered sheet, matching its species, thickness, units, and stock dimensions. Each sheet file has its own 0,0 origin.
        2. Import the matching TOP DXF. SHEET and LABELS are reference layers. OUTLINE is the finished material boundary: use an outside profile toolpath and add hold-down tabs in VCarve. Keep the stock intact until both sides are complete; run the final through profile last.
        3. POCKET_<depth> layers identify actual cutting depth and units. An inner closed contour on the same pocket layer is an island that must remain uncut; verify the pocket toolpath preview. DRILL/COUNTERBORE/COUNTERSINK/DOVETAIL names identify operation type. Match the tool, depth, and feeds to your setup. Relief geometry is already present; do not add dogbones twice.
        4. Use the cutter diameter saved with each relief. Apply cutter compensation in VCarve; exported contours are part geometry, not tool centerlines. Do not machine SHEET, LABELS, or TENON as automatic pocket boundaries. TENON is a shoulder reference.
        5. For BOTTOM files, flip around the sheet LENGTH axis and keep the same X datum. The vectors are already mirrored in Y; do not mirror them again. REFERENCE_OUTLINE in a bottom file is for alignment only, not a cutting layer. Registration holes are symmetric about that flip and occupy a reserved strip outside the nested parts.
        6. SIDE files require a separate fixture. Their names specify the face and U/V coordinate axes. Their origin is the minimum U/V corner of that stock face. Review the setup orientation and depth before machining.
        7. Use VCarve to generate and simulate toolpaths, add tabs, select feeds/speeds, and post G-code for your machine. No machine code is included in this package.

        Part-specific negative-face-up choices are included in layout geometry and placement metadata. The job-level BOTTOM flip is separate from that choice.

        The JSON contains original part geometry, feature depths, tapers, relief cutter sizes, expressions, placements, and parameters. JSON model coordinates are explicitly in inches; DXF/SVG use the vector units above.

        Part identifiers P001, P002, etc. match the model, printable labels, drawings, cut-list IDs, and placement metadata. Joint identifiers match the assembly callouts.

        Grain match map.csv records ordered panels on the same sheet, aligned with the sheet length grain. Keep the mapped order and orientation when cutting and assembling a matched run. Set the first panel's order explicitly in the Materials panel.

        Setup notes:
        \((notes + issues.map(\.message)).joined(separator:"\n"))
        """
        artifacts.append(VCarveArtifact(name: "READ ME - VCarve setup.txt", data: Data(instructions.utf8)))
        let files = artifacts.filter { $0.name.hasSuffix(".dxf") }.map { "• "+$0.name+"\n  Visual guide: "+String($0.name.dropLast(4))+" - Setup.pdf" }.joined(separator:"\n\n")
        artifacts.append(VCarveArtifact(name:"START HERE - Import files.txt",data:Data(("VCarve import checklist\n\nUnits: \(project.metric ? "millimeters" : "inches")\nOne job per sheet / fixture. XY origin is the bottom-left stock corner (0,0).\nUse the stock size and material thickness shown in each setup PDF and filename.\n\n"+files+"\n\nLayer guide\n"+VCarveLayerGuide.rows.map { $0.0+": "+$0.1 }.joined(separator:"\n")+"\n\nRead READ ME - VCarve setup.txt for toolpath order, bottom-face flipping, and registration.\n").utf8)))
        var audit = ["Serialized DXF vector audit", "Units: \(project.metric ? "millimeters" : "inches")", "These structural checks do not replace opening and simulating the job in VCarve.", ""]
        for item in artifacts where item.name.lowercased().hasSuffix(".dxf") {
            let checked = try CNCVectorAudit.validate(item.data,metric:project.metric)
            audit.append("\(item.name): \(checked.polylines) closed loops, \(checked.vertices) vertices; layers: \(checked.layers.joined(separator:", "))")
        }
        artifacts.append(VCarveArtifact(name:"DXF vector audit.txt",data:Data(audit.joined(separator:"\n").utf8)))
        return artifacts
    }
    /// Publish a complete package with one rename; failed writes leave no partial job folder.
    static func write(_ artifacts: [VCarveArtifact], to destination: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath:destination.path),!artifacts.isEmpty else { throw ModelValidation.Failure(message:"Choose a new destination for the complete VCarve job.") }
        var names: Set<String> = []
        for artifact in artifacts {
            guard !artifact.name.isEmpty,artifact.name != ".",artifact.name != "..",!artifact.name.contains("/"),!artifact.name.contains(":"),
                  names.insert(artifact.name.lowercased()).inserted,!artifact.data.isEmpty else { throw ModelValidation.Failure(message:"The export contains an invalid, empty, or duplicate file.") }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".WoodShop-export-"+UUID().uuidString)
        try manager.createDirectory(at:staging,withIntermediateDirectories:false)
        defer { try? manager.removeItem(at:staging) }
        for artifact in artifacts { try artifact.data.write(to:staging.appendingPathComponent(artifact.name),options:.atomic) }
        try manager.moveItem(at:staging,to:destination)
    }
}
extension Document {
    func exportVCarveJob() {
        guard prepareForExport() else { return }
        finishDrag?()
        do {
            let artifacts = try VCarveExport.artifacts(project: cncProject)
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.prompt = "Export VCarve Job"; panel.message = "Choose a folder. A new job subfolder will contain one DXF per sheet/setup, previews, parameters, and a cut list."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HHmmss"
            let destination = folder.appendingPathComponent(VCarveExport.filename(fileName) + " VCarve " + stamp.string(from: Date()) + " " + UUID().uuidString.prefix(4))
            try VCarveExport.write(artifacts,to:destination)
            status = "Exported VCarve job: \(artifacts.count) files with setup notes and parameters."
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { status = "VCarve export blocked: " + error.localizedDescription }
    }
}
