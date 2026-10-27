import XCTest
@testable import WoodShop

final class RobustnessTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    func board() -> Part {
        var p = Part(name:"Panel",origin:.zero,size:SIMD3(20,0.75,10),species:.plywood)
        p.thicknessAxis = 1; p.grainDirection = 0; return p
    }
    func doc(_ root: URL) -> Document { Document(startRecoveryTimer:false,recoveryLocation:root.appendingPathComponent("Recovery.json"),setupStoreURL:root.appendingPathComponent("Setups.json")) }
    func testMalformedAxesAreRejectedBeforeGeometryEvenWhenSuppressed() throws {
        for axis in [-1,3,Int.max] {
            var p = board(); p.cuts = [Cut(kind:"Mortise",lo:SIMD3(1,0.25,1),hi:SIMD3(2,0.75,2),faceAxis:axis,relief:CornerRelief(),suppressed:true)]
            XCTAssertNotNil(ModelValidation.part(p))
            var project = Project(); project.parts = [p]
            XCTAssertThrowsError(try Document.decodeProject(JSONEncoder().encode(project)))
            XCTAssertThrowsError(try Regeneration.rebuild(parts:&project.parts,links:[],studio:StudioState()))
        }
        var p = board(); p.operations = [MachiningOperation(name:"Invalid",axis:4,positive:true,depth:0.5,contour:[],suppressed:true)]
        XCTAssertNotNil(ModelValidation.part(p))
    }
    func testDuplicateFeaturesMissingHistoryAndOrphanedMatesRejected() throws {
        var p = board()
        let cut = Cut(kind:"Mortise",lo:SIMD3(1,0.25,1),hi:SIMD3(2,0.75,2),faceAxis:1)
        var op = MachiningOperation(name:"Pocket",axis:1,positive:true,depth:0.5,contour:[SIMD2(4,4),SIMD2(5,4),SIMD2(5,5),SIMD2(4,5)])
        op.id = cut.id; p.cuts = [cut]; p.operations = [op]
        XCTAssertNotNil(ModelValidation.part(p))
        p.operations = nil; p.featureOrder = [FeatureStep(kind:.cut,feature:UUID())]
        XCTAssertNotNil(ModelValidation.part(p))
        p.featureOrder = nil; p.cuts[0].mateID = UUID()
        var project = Project(); project.parts = [p]
        XCTAssertThrowsError(try ModelValidation.validate(project))
    }
    func testDegenerateImportedMeshRejected() {
        var p = board(); p.mesh = MeshSolid(faces:[[.zero,SIMD3(0.5,0,0),SIMD3(1,0,0)]])
        XCTAssertNotNil(ModelValidation.part(p))
    }
    func testEditingInvalidAxisLeavesProjectAndRedoIntact() throws {
        let d = doc(try folder()),p = board(); d.add(p); d.edit(p.id) { $0.name = "Changed" }; d.undo()
        let before = d.project
        d.edit(p.id) { $0.thicknessAxis = 9; $0.size.x = 30 }
        XCTAssertEqual(d.project,before); XCTAssertTrue(d.canRedo)
        d.redo(); XCTAssertEqual(d.part(p.id)?.name,"Changed")
    }
    func testAssemblyTranslationStagesAllLinkedPartsAndRollsBackFailures() throws {
        let d = doc(try folder())
        var side = Part(name:"Side",origin:.zero,size:SIMD3(0.75,24,10),species:.plywood); side.thicknessAxis = 0; side.grainDirection = 1
        var shelf = board(); shelf.origin = SIMD3(0.75,5,0)
        d.add(side); d.add(shelf)
        XCTAssertTrue(d.createMatingJoint(MatingJoint(shelf:shelf.id,receiver:side.id,axis:0,positive:true,autoSeat:false)),d.status)
        var moved = d.parts
        for i in moved.indices { moved[i].origin += SIMD3(10,10,10) }
        XCTAssertTrue(d.applyPartChanges(moved),d.status)
        XCTAssertEqual(d.part(side.id)!.origin,SIMD3(10,10,10))
        XCTAssertEqual(d.part(side.id)!.cuts[0].lo.y,5,accuracy:1e-8)
        let before = d.project
        moved = d.parts; moved[moved.firstIndex { $0.id == shelf.id }!].origin.y = 200
        XCTAssertFalse(d.applyPartChanges(moved)); XCTAssertEqual(d.project,before)
    }
    func testDuplicatePartIDDoesNotCorruptDocument() throws {
        let d = doc(try folder()),p = board(); d.add(p); let before = d.project
        d.add(p); XCTAssertEqual(d.parts.count,1); XCTAssertEqual(d.project,before)
        var orphan = board(); orphan.cuts = [Cut(kind:"Mortise",lo:SIMD3(1,0.25,1),hi:SIMD3(2,0.75,2),faceAxis:1,mateID:UUID())]
        d.add(orphan); XCTAssertEqual(d.project,before)
        d.rotateSelected(axis:Int.max); XCTAssertEqual(d.project,before)
    }
    func testPreviousSaveIsReadableAndRestorationIsUndoable() throws {
        let root = try folder(),d = doc(root),p = board(),url = root.appendingPathComponent("Cabinet.wood")
        d.add(p); try d.writeProject(to:url)
        d.edit(p.id) { $0.name = "Second saved version" }; try d.writeProject(to:url)
        XCTAssertTrue(d.canRestorePreviousSave)
        let backup = try Document.decodeProject(Data(contentsOf:ProjectStorage.previousURL(url)))
        XCTAssertEqual(backup.parts[0].name,"Panel")
        d.restorePreviousSave(); XCTAssertEqual(d.parts[0].name,"Panel"); XCTAssertTrue(d.isDirty)
        XCTAssertEqual(try Document.decodeProject(Data(contentsOf:url)).parts[0].name,"Second saved version")
        d.undo(); XCTAssertEqual(d.parts[0].name,"Second saved version"); XCTAssertFalse(d.isDirty)
    }
    func testExternallyChangedProjectIsPreservedAndSaveAsWorks() throws {
        let root = try folder(),d = doc(root),p = board(),url = root.appendingPathComponent("Cabinet.wood")
        d.add(p); try d.writeProject(to:url)
        var external = d.project; external.parts[0].name = "Changed by another application"
        let data = try JSONEncoder().encode(external); try data.write(to:url,options:.atomic)
        d.edit(p.id) { $0.name = "My unsaved change" }
        XCTAssertThrowsError(try d.writeProject(to:url)); XCTAssertEqual(try Data(contentsOf:url),data); XCTAssertTrue(d.isDirty)
        let copy = root.appendingPathComponent("My copy.wood"); try d.writeProject(to:copy)
        XCTAssertEqual(try Document.decodeProject(Data(contentsOf:copy)).parts[0].name,"My unsaved change")
        XCTAssertFalse(d.isDirty)
    }
    func testRecoveryFallsBackToPreviousValidFile() throws {
        let root = try folder(),d = doc(root),p = board(),url = root.appendingPathComponent("Recovery.json")
        d.add(p); d.autosaveRecovery(); let first = d.project
        d.edit(p.id) { $0.name = "More work" }; d.autosaveRecovery()
        try Data("incomplete write".utf8).write(to:url)
        XCTAssertEqual(try ProjectStorage.recovery(at:url).project,first)
        d.edit(p.id) { $0.name = "Latest work" }; d.autosaveRecovery()
        XCTAssertEqual(try ProjectStorage.recovery(at:url).project,d.project)
        XCTAssertEqual(try JSONDecoder().decode(Document.Recovery.self,from:Data(contentsOf:ProjectStorage.previousURL(url))).project,first)
    }
    func testSetupLibraryRecoversAndDoesNotReplaceGoodBackupWithCorruption() throws {
        let root = try folder(),url = root.appendingPathComponent("Setups.json"),store = SetupProfileStore(url:url)
        let first = CNCSetupProfile(); try store.save([first])
        var second = first; second.name = "Changed"; try store.save([second])
        try Data("bad JSON".utf8).write(to:url)
        XCTAssertEqual(store.load(),[first]); XCTAssertNotNil(store.loadError)
        try store.save([second]); XCTAssertEqual(store.load(),[second])
        XCTAssertEqual(try JSONDecoder().decode([CNCSetupProfile].self,from:Data(contentsOf:ProjectStorage.previousURL(url))),[first])
        XCTAssertThrowsError(try store.save([first,first]))
    }
    func testEdgePocketCannotAppearInTopFaceToolpath() throws {
        var p = board()
        p.cuts = [Cut(kind:"Mortise",lo:SIMD3(19.5,0,2),hi:SIMD3(20,0.75,3),faceAxis:0,facePositive:true,runAxis:2)]
        let flat = Flatten.flat(p)
        XCTAssertEqual(flat.features.first?.side,.edge)
        var project = Project(); project.parts = [p]
        let artifacts = try VCarveExport.artifacts(project:project)
        let top = try XCTUnwrap(artifacts.first { $0.name.contains("TOP.dxf") }),text = String(decoding:top.data,as:UTF8.self)
        XCTAssertFalse(text.contains("POCKET_")); XCTAssertFalse(text.contains("CUTOUT_THROUGH"))
        let side = try XCTUnwrap(artifacts.first { $0.name.contains("SIDE +X") && $0.name.hasSuffix(".dxf") })
        XCTAssertTrue(String(decoding:side.data,as:UTF8.self).contains("POCKET_0.5in"))
    }
    func testBuriedPocketAndEntireStockRemovalBlockCNCExport() {
        var p = board(),project = Project()
        p.cuts = [Cut(kind:"Mortise",lo:SIMD3(2,0.1,2),hi:SIMD3(3,0.5,3),faceAxis:1,facePositive:true)]
        project.parts = [p]
        XCTAssertTrue(MachiningReview.issues(project:project).contains { $0.code == "inaccessible-pocket" && $0.severity == .error })
        XCTAssertThrowsError(try VCarveExport.artifacts(project:project))
        p.cuts = [Cut(kind:"Pocket",lo:.zero,hi:p.size,faceAxis:1,facePositive:true)]; project.parts = [p]
        XCTAssertTrue(MachiningReview.issues(project:project).contains { $0.code == "empty-part" })
    }
    func testDrillAssignmentMustMatchHoleDiameter() throws {
        var p = board(),setup = CNCSetupProfile(),project = Project()
        p.operations = try JoineryTools.holes(part:p,axis:1,positive:true,centers:[SIMD2(2,2)],diameter:0.25,depth:0.5)
        setup.tools[0].kind = .drill; setup.tools[0].diameter = 0.375
        project.parts = [p]; project.studio = StudioState(); project.studio!.setupProfile = setup
        XCTAssertTrue(MachiningReview.issues(project:project).contains { $0.code == "drill-tool" && $0.severity == .error })
        setup.tools[0].diameter = 0.25; project.studio!.setupProfile = setup
        XCTAssertFalse(MachiningReview.issues(project:project).contains { $0.code == "drill-tool" })
    }
    func testStalePatternExpressionsRejectedUntilRegenerated() throws {
        var p = board(),recipe = DrillingPattern(),project = Project(); recipe.columns = 3
        recipe.expressions = [PatternExpression(field:.columns,expression:"5")]; p.patterns = [recipe]; project.parts = [p]
        XCTAssertThrowsError(try ModelValidation.validate(project))
        try Regeneration.rebuild(parts:&project.parts,links:[],studio:StudioState())
        XCTAssertNoThrow(try ModelValidation.validate(project)); XCTAssertEqual(project.parts[0].machiningOperations.count,5)
    }
    func testUnreasonablyNestedExpressionsFailWithoutStackOverflow() {
        let expression = String(repeating:"(",count:200)+"1in"+String(repeating:")",count:200)
        XCTAssertThrowsError(try Parametric.values([DesignParameter(name:"nested",expression:expression)]))
        XCTAssertThrowsError(try Parametric.values([DesignParameter(name:"long",expression:String(repeating:"1+",count:5000)+"1")]))
        let chain = (0..<100).map { DesignParameter(name:"n\($0)",expression:$0 == 99 ? "1in" : "n\($0+1)") }
        XCTAssertThrowsError(try Parametric.values(chain))
    }
    func testVCarvePackagePublishesCompletelyAndRejectsBadPathsOrOverwrite() throws {
        let root = try folder(),target = root.appendingPathComponent("Job"),files = [VCarveArtifact(name:"TOP.dxf",data:Data("vectors".utf8)),VCarveArtifact(name:"Read me.txt",data:Data("setup".utf8))]
        try VCarveExport.write(files,to:target)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:target.path).sorted(),files.map(\.name).sorted())
        XCTAssertThrowsError(try VCarveExport.write(files,to:target))
        for bad in [[VCarveArtifact(name:"../escape",data:Data([1]))],[files[0],files[0]],[VCarveArtifact(name:"empty",data:Data())]] {
            let unused = root.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try VCarveExport.write(bad,to:unused)); XCTAssertFalse(FileManager.default.fileExists(atPath:unused.path))
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix(".WoodShop-export-") })
    }
    func testIndividualHoleCanMoveAndResizeWithoutLosingIdentity() throws {
        let p = board(),op = try JoineryTools.holes(part:p,axis:1,positive:true,centers:[SIMD2(2,2)],diameter:0.25,depth:0.5)[0]
        let moved = try op.repositioned(center:SIMD2(4,5),span:SIMD2(repeating:0.375))
        XCTAssertEqual(moved.id,op.id); XCTAssertEqual(moved.depth,op.depth)
        XCTAssertEqual(moved.openingBounds.center,SIMD2(4,5))
        XCTAssertEqual(moved.openingBounds.span.x,0.375,accuracy:1e-7)
        XCTAssertNil(moved.validation(size:p.size))
        XCTAssertThrowsError(try op.repositioned(center:.zero,span:.zero))
    }
    func testOperationSavePropagatesComponentsAndRejectsInvalidGeometryAtomically() throws {
        let d = doc(try folder()); var p = board()
        p.operations = try JoineryTools.holes(part:p,axis:1,positive:true,centers:[SIMD2(2,2)],diameter:0.25,depth:0.5)
        d.add(p); d.makeComponents(); d.duplicateSelected()
        let copy = try XCTUnwrap(d.selectedPart),op = try p.operations![0].repositioned(center:SIMD2(4,5),span:SIMD2(repeating:0.375))
        XCTAssertTrue(d.saveOperation(op,partID:p.id),d.status)
        XCTAssertEqual(d.part(copy.id)?.operations?.first,op)
        let before = d.project
        var invalid = op; invalid.depth = 2
        XCTAssertFalse(d.saveOperation(invalid,partID:p.id)); XCTAssertEqual(d.project,before)
        d.undo(); XCTAssertEqual(d.part(p.id)?.operations,p.operations)
    }

    func testRecoveredProjectRetainsOriginalDiskConflictDetection() throws {
        let root = try folder(),d = doc(root),p = board(),url = root.appendingPathComponent("Cabinet.wood")
        d.add(p); try d.writeProject(to:url)
        d.edit(p.id) { $0.name = "Unsaved before crash" }; d.autosaveRecovery()
        let recovery = try ProjectStorage.recovery(at:root.appendingPathComponent("Recovery.json"))
        var external = d.project; external.parts[0].name = "Other work since crash"
        let data = try JSONEncoder().encode(external); try data.write(to:url)
        let recovered = doc(root); try recovered.restoreRecovery(recovery)
        XCTAssertEqual(recovered.parts[0].name,"Unsaved before crash")
        XCTAssertThrowsError(try recovered.writeProject(to:url)); XCTAssertEqual(try Data(contentsOf:url),data)
    }
    func testCSGRejectsNonfiniteFacesAndHandlesCollinearLeadingMeshVertices() {
        XCTAssertNil(SolidCSG.face([.zero,SIMD3(1,0,0),SIMD3(0,1,0)],normal:SIMD3(.nan,0,0)))
        let mesh = MeshSolid(faces:[[.zero,SIMD3(0.5,0,0),SIMD3(1,0,0),SIMD3(1,1,0),SIMD3(0,1,0)]])
        let polygons = mesh.polygons(size:SIMD3(repeating:1))
        XCTAssertEqual(polygons.count,1); XCTAssertEqual(polygons.first?.n,SIMD3(0,0,1))
    }

}
