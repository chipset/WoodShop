import AppKit
import UniformTypeIdentifiers
import simd

struct ProjectBackupInfo: Identifiable {
    var id: URL { url }
    var url: URL
    var summary: String
    var project: Project?

    static func inspect(doc: Document) -> [ProjectBackupInfo] {
        var candidates: [(URL,Bool)] = []
        if let url = doc.activeProjectURL { candidates += ([url]+ProjectStorage.backupURLs(url)).map { ($0,false) } }
        candidates += ([doc.recoveryFileURL]+ProjectStorage.backupURLs(doc.recoveryFileURL)).map { ($0,true) }
        return candidates.compactMap { url,isRecovery in
            guard FileManager.default.fileExists(atPath:url.path) else { return nil }
            do {
                let data = try Data(contentsOf:url)
                let project = try isRecovery ? JSONDecoder().decode(Document.Recovery.self,from:data).project : JSONDecoder().decode(Project.self,from:data)
                try ModelValidation.validate(project)
                let date = (try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate).map { DateFormatter.localizedString(from:$0,dateStyle:.medium,timeStyle:.short) } ?? "Unknown date"
                return ProjectBackupInfo(url:url,summary:"Valid · \(project.parts.count) parts · \(date) · \(ProjectStorage.fingerprint(data).prefix(12))",project:project)
            } catch { return ProjectBackupInfo(url:url,summary:"Unreadable: "+error.localizedDescription,project:nil) }
        }
    }
}

enum ShopValidation {
    static let usabilityChecklist = """
    WoodShop Make workspace · observed usability session
    Participant: __________________  Woodworking/CNC experience: __________________
    Project copy: __________________  App version: __________  Observer: __________
    Let the participant work without hints. Time each task from reading to completion. Record the first click, wrong turns, help requests, recovery, and whether they could explain the result. Stop a task after five minutes, then note what blocked it.

    Task 1 · Find part P___, change a driven cabinet dimension, and explain which parts updated.
    Task 2 · Select a face, sketch a rounded pocket with an island, then reopen and edit it.
    Task 3 · Open Make, choose parts, set stock and cutter, inspect sheets, and resolve one machining warning.
    Task 4 · Add a measured offcut and an ordered grain run. Identify both the nested sheet and grain match map.
    Task 5 · Find a documented hardware template, apply it to the intended face, and explain which hole sizes still need confirmation.
    Task 6 · Export the VCarve job, identify the TOP DXF and its setup PDF, and explain the BOTTOM flip and SIDE fixture.
    Task 7 · Find the assembly checks, dimensioned exploded guide, cut list, labels, and saved recovery copies.

    For each task: elapsed time ____  completed without help Y/N ____  errors ____  first click ____
    Notes / exact wording that caused hesitation: _________________________________________________
    Overall: tasks completed without help ____ / 7  most serious issue _____________________________
    Follow-up change, owner, and retest date: _____________________________________________________

    VCarve import and simulation require an operator with VCarve. Validate actual units, stock, layers, islands, depths, registration, and flips before machining.
    """

    static func fixture(metric: Bool) throws -> Project {
        var part = Part(name:"Validation panel",origin:.zero,size:SIMD3(16,0.75,12),species:.plywood)
        part.thicknessAxis = 1;part.grainDirection = 0
        func feature(_ title: String,axis: Int,positive: Bool,sketch: FaceSketch) throws -> MachiningOperation {
            let source = MachiningOperation(name:title,axis:axis,positive:positive,depth:sketch.depth,contour:[],sketch:sketch)
            return try sketch.generated(from:source,size:part.size,values:[:])
        }
        var island = FaceSketch.seed(part:part,axis:1)
        island.shape = .roundedRectangle;island.mode = .pocket;island.center = SIMD2(3.4,3.5);island.size = SIMD2(3.4,4);island.cornerSize = 0.35;island.islandInset = 0.55
        var curve = FaceSketch.seed(part:part,axis:1)
        curve.shape = .arc;curve.mode = .groove;curve.center = SIMD2(8,5);curve.size = SIMD2(4,4);curve.grooveWidth = 0.3;curve.depth = 0.18
        var bottom = FaceSketch.seed(part:part,axis:1)
        bottom.shape = .slot;bottom.mode = .pocket;bottom.center = SIMD2(8,11.5);bottom.size = SIMD2(1.5,3);bottom.depth = 0.2
        var edge = FaceSketch.seed(part:part,axis:0)
        edge.shape = .rectangle;edge.mode = .pocket;edge.center = SIMD2(0.375,5);edge.size = SIMD2(0.3,1.5);edge.depth = 0.125
        part.operations = [try feature("Pocket with island",axis:1,positive:true,sketch:island),try feature("Curved groove",axis:1,positive:true,sketch:curve),try feature("Bottom slot",axis:1,positive:false,sketch:bottom),try feature("Edge fixture pocket",axis:0,positive:true,sketch:edge)]
        part.featureOrder = part.featureSteps
        var project = Project();project.parts = [part];project.metric = metric;project.sheetLength = 24;project.sheetWidth = 24
        try ModelValidation.validate(project)
        return project
    }

    static func artifacts() throws -> [VCarveArtifact] {
        var files: [VCarveArtifact] = []
        for metric in [false,true] {
            let prefix = metric ? "Millimeters - " : "Inches - "
            let items = try VCarveExport.artifacts(project:fixture(metric:metric))
            files += items.map { VCarveArtifact(name:prefix+$0.name,data:$0.data) }
        }
        let guide = """
        VCarve manual import validation
        This package is generated from one representative test panel in both unit systems. The same geometry should measure 16 × 12 inches or 406.4 × 304.8 mm. Stock is 24 × 24 inches or 609.6 × 609.6 mm, thickness 0.75 inches or 19.05 mm.

        In VCarve, create separate jobs for Inches and Millimeters. For each, record the VCarve version, operator, screenshot, observed measurement, warnings, and PASS/FAIL.

        TOP: Import the numbered TOP DXF. Confirm the part outline, one pocket with an inner island, and a curved groove. Create toolpaths only from intended cutting layers. Simulate: the island center remains uncut. Check cutter, cut depth, stock origin, and hold-down tabs.
        BOTTOM: Import the BOTTOM-FLIP-LENGTH-AXIS DXF in a separate bottom-face job. Flip physical stock about its length axis. Keep X fixed; Y is already mirrored. Do not mirror the imported vectors again. Verify registration and simulate the bottom slot.
        SIDE: Import the SIDE DXF in a separate edge fixture job. Follow its setup PDF for face and U/V directions. Check local origin, stock thickness, pocket depth, and simulate.
        Compare the inch and millimeter results: model and stock should be geometrically identical after unit conversion. Save screenshots of each imported setup and toolpath simulation.

        TOP inch: observed size ________ layers ________ simulation ________ PASS/FAIL ________
        TOP mm: observed size __________ layers ________ simulation ________ PASS/FAIL ________
        BOTTOM: flip and registration ______________________________ PASS/FAIL ________
        SIDE: face, origin, and fixture ____________________________ PASS/FAIL ________
        Operator/version ____________________ Date ___________ Evidence folder ____________________
        Unresolved finding and owner ______________________________________________________________

        WoodShop structurally audits the DXF vectors. These import and simulation checks remain pending until a person completes them in VCarve.
        """
        files.append(VCarveArtifact(name:"START HERE - Manual VCarve import validation.txt",data:Data(guide.utf8)))
        files.append(VCarveArtifact(name:"Observed woodworking usability session.txt",data:Data(usabilityChecklist.utf8)))
        return files
    }
}

extension Document {
    func exportExplodedGuide() {
        guard prepareForExport() else { return }
        let panel = NSSavePanel();panel.allowedContentTypes = [.pdf];panel.nameFieldStringValue = fileName+" exploded assembly.pdf"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { try ExplodedGuide.pdf(project:project).write(to:url,options:.atomic);status = "Saved dimensioned exploded assembly guide." }
        catch { status = error.localizedDescription }
    }
    func exportVCarveValidation() {
        let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.canCreateDirectories = true
        guard panel.runModal() == .OK,let folder = panel.url else { return }
        do {
            let destination = folder.appendingPathComponent("WoodShop VCarve validation "+UUID().uuidString.prefix(6))
            let artifacts = try ShopValidation.artifacts()
            try VCarveExport.write(artifacts,to:destination)
            status = "Created VCarve validation package with inch and millimeter fixtures."
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { status = "Validation package failed: "+error.localizedDescription }
    }
}
