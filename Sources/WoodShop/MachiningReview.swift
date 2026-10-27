import Foundation
import simd

enum ReviewSeverity: Int,Comparable { case information = 0,warning = 1,error = 2; static func <(a:Self,b:Self)->Bool { a.rawValue < b.rawValue } }
struct MachiningIssue: Identifiable {
    var part: UUID
    var feature: FeatureRef?
    var point: SIMD3<Double>
    var severity: ReviewSeverity
    var code: String
    var message: String
    var id: String { part.uuidString + (feature?.id ?? "") + code }
}
enum MachiningReview {
    private struct Region {
        var ref: FeatureRef
        var lo: SIMD3<Double>
        var hi: SIMD3<Double>
        var kind: String
        var center: SIMD3<Double> { (lo+hi)/2 }
    }
    static func issues(project: Project) -> [MachiningIssue] {
        var result: [MachiningIssue] = []
        let setup = project.studio?.setupProfile
        for part in project.parts where part.hardware != true {
            if let message = ModelValidation.part(part) {
                result.append(MachiningIssue(part:part.id,point:.zero,severity:.error,code:"invalid-part",message:part.name + ": " + message)); continue
            }
            var regions: [Region] = []
            func add(_ ref: FeatureRef?,_ point: SIMD3<Double>,_ severity: ReviewSeverity,_ code: String,_ message: String) {
                result.append(MachiningIssue(part:part.id,feature:ref,point:point,severity:severity,code:code,message:ShopIdentity.label(part) + " " + part.name + ": " + message))
            }
            func tool(_ ref: FeatureRef) -> CuttingTool? {
                if let id = part.toolAssignments?[ref.feature.uuidString] {
                    if let tool = setup?.tools.first(where: { $0.id == id }) { return tool }
                    add(ref,part.size/2,.error,"missing-tool","the assigned cutter is missing from the selected CNC setup.")
                }
                return setup?.defaultTool
            }
            func check(_ ref: FeatureRef,_ lo: SIMD3<Double>,_ hi: SIMD3<Double>,axis: Int,depth: Double,kind: String,relief: CornerRelief? = nil) {
                let point = (lo+hi)/2,u = (axis+1)%3,v = (axis+2)%3
                let cutter = tool(ref)
                if let cutter {
                    if depth > cutter.fluteLength + 1e-6 { add(ref,point,.error,"reach","depth \(Units.format(depth,metric:project.metric)) exceeds \(cutter.name)'s flute length. Use a suitable cutter or another setup.") }
                    let width = min(hi[u]-lo[u],hi[v]-lo[v])
                    if cutter.kind == .endMill && width < cutter.diameter-1e-6 {
                        let severity: ReviewSeverity = part.toolAssignments?[ref.feature.uuidString] == nil ? .warning : .error
                        add(ref,point,severity,"narrow","this feature is narrower than \(cutter.name). Assign a smaller mill or the intended drill.")
                    }
                    if let relief,abs(relief.diameter-cutter.diameter)>1e-6 || cutter.kind != .endMill {
                        add(ref,point,.error,"relief-tool","relief was designed for a \(Units.format(relief.diameter,metric:project.metric)) mill; the selected cutter is \(cutter.name). Update the relief or cutter assignment.")
                    }
                    if cutter.kind == .drill {
                        if kind != "Drill" || abs(min(hi[u]-lo[u],hi[v]-lo[v])-cutter.diameter) > 1e-5 {
                            add(ref,point,.error,"drill-tool","the selected drill does not match this hole's diameter or operation type. Choose a matching drill or a suitable milling tool.")
                        }
                    }
                    if kind == "Countersink" && cutter.kind != .vBit { add(ref,point,.warning,"sink-tool","the countersink needs a matching included-angle tool or a separate machining strategy.") }
                    if kind == "Dovetail" && cutter.kind != .dovetail { add(ref,point,.warning,"dovetail-tool","the tapered joint needs a dovetail cutter or a 3D machining setup.") }
                }
                let threshold = (cutter?.diameter ?? 0.25)/2
                let walls = [lo[u],lo[v],part.size[u]-hi[u],part.size[v]-hi[v]].filter { $0 > 1e-6 }
                if let wall = walls.min(),wall < threshold {
                    add(ref,point,.warning,"thin-wall","only \(Units.format(wall,metric:project.metric)) of material remains beside this feature. Check the wall and hold-down method.")
                }
                if axis != part.materialAxes.t { add(ref,point,.information,"edge-setup","this feature requires a separate edge/end fixture. Its vectors are exported in a SIDE setup file.") }
                regions.append(Region(ref:ref,lo:lo,hi:hi,kind:kind))
            }
            for cut in part.cuts where cut.suppressed != true && !cut.additive {
                let ref = FeatureRef(part:part.id,kind:.cut,feature:cut.id),axis = cut.faceAxis ?? part.materialAxes.t
                var lo = cut.lo,hi = cut.hi
                let shape = cut.machiningContour(part:part),u = (axis+1)%3,v = (axis+2)%3
                lo[u] = shape.map(\.x).min()!; hi[u] = shape.map(\.x).max()!; lo[v] = shape.map(\.y).min()!; hi[v] = shape.map(\.y).max()!
                check(ref,lo,hi,axis:axis,depth:cut.hi[axis]-cut.lo[axis],kind:cut.kind,relief:cut.relief)
                let positive = cut.facePositive ?? (cut.hi[axis] >= part.size[axis]-1e-6)
                if positive ? cut.hi[axis] < part.size[axis]-1e-6 : cut.lo[axis] > 1e-6 {
                    add(ref,(lo+hi)/2,.error,"inaccessible-pocket","this pocket does not open onto its machining face. Change its depth/face or use a suitable 3D manufacturing strategy.")
                }
                if (0..<3).allSatisfy({ cut.lo[$0] <= 1e-6 && cut.hi[$0] >= part.size[$0]-1e-6 }),!part.cuts.contains(where: { $0.additive && $0.suppressed != true }) {
                    add(ref,part.size/2,.error,"empty-part","this cut removes the entire part. Suppress it or reduce its extent before machining.")
                }
                if cut.relief == nil,lo[u]>1e-6,lo[v]>1e-6,hi[u]<part.size[u]-1e-6,hi[v]<part.size[v]-1e-6 {
                    add(ref,(lo+hi)/2,.warning,"square-corners","a round cutter leaves rounded internal corners here. Add corner reliefs or round the mating part's corners.")
                }
            }
            for op in part.machiningOperations where op.suppressed != true {
                let ref = FeatureRef(part:part.id,kind:op.patternID == nil ? .operation : .pattern,feature:op.patternID ?? op.id)
                var lo = SIMD3<Double>.zero,hi = part.size
                lo[op.u] = op.contour.map(\.x).min()!; hi[op.u] = op.contour.map(\.x).max()!
                lo[op.v] = op.contour.map(\.y).min()!; hi[op.v] = op.contour.map(\.y).max()!
                lo[op.axis] = op.positive ? part.size[op.axis]-op.depth : 0; hi[op.axis] = op.positive ? part.size[op.axis] : op.depth
                check(ref,lo,hi,axis:op.axis,depth:op.depth,kind:op.kind)
                if let sketch = op.sketch,sketch.mode == .groove,
                   let evaluated = try? sketch.evaluated(Parametric.values(project.studio?.parameters ?? [])),
                   let cutter = tool(ref),cutter.kind == .endMill,cutter.diameter > evaluated.grooveWidth+1e-6 {
                    add(ref,(lo+hi)/2,.error,"sketch-groove-tool","the groove is \(Units.format(evaluated.grooveWidth,metric:project.metric)) wide, smaller than \(cutter.name). Assign a smaller mill or increase the groove width.")
                }
                if let profile = part.profile,profile.thickness == op.axis,["Drill","Counterbore","Countersink"].contains(op.kind) {
                    let boundary = profile.contour(size:part.size)
                    let outside = op.contour.contains { pt in
                        var local = SIMD3<Double>.zero; local[op.u] = pt.x; local[op.v] = pt.y
                        return !GeometryImport.contains(SIMD2(local[profile.u],local[profile.v]),polygon:boundary)
                    }
                    if outside { add(ref,(lo+hi)/2,.error,"outside-profile","this hole/recess leaves the actual shaped outline. Move it inward or change the outline.") }
                }
            }
            // A flat machining file cannot reproduce material added after a pocket.
            // Test actual solid overlap so nearby, disjoint features remain exportable.
            var earlier: [(FeatureStep,[Geo.Poly])] = []
            for step in part.featureSteps {
                let tool = part.toolPolygons(step)
                guard !tool.isEmpty else { continue }
                if step.kind == .cut,part.cuts.first(where: { $0.id == step.feature })?.additive == true {
                    for (old,removed) in earlier {
                        let overlap = SolidCSG.intersection(tool,removed)
                        var volume = 0.0
                        for polygon in overlap where polygon.pts.count >= 3 {
                            for i in 1..<(polygon.pts.count-1) { volume += simd_dot(polygon.pts[0],simd_cross(polygon.pts[i],polygon.pts[i+1]))/6 }
                        }
                        if abs(volume) > 1e-8 {
                            add(FeatureRef(part:part.id,kind:step.kind,feature:step.feature),part.size/2,.error,"refilled-"+old.id,
                                "‘\(part.featureName(step))’ restores material removed by ‘\(part.featureName(old))’. Reorder these features before exporting flat CNC vectors, or export the final 3D solid for a 3D strategy.")
                        }
                    }
                } else { earlier.append((step,tool)) }
            }
            for i in regions.indices { for j in regions.indices where j>i {
                let a = regions[i],b = regions[j]
                let extent = pointwiseMin(a.hi,b.hi)-pointwiseMax(a.lo,b.lo)
                guard extent.x>1e-6,extent.y>1e-6,extent.z>1e-6 else { continue }
                let heads: Set<String> = ["Drill","Counterbore","Countersink"]
                if heads.contains(a.kind),heads.contains(b.kind),a.kind != b.kind {
                    let normal = part.materialAxes.t
                    let u = (normal+1)%3,v = (normal+2)%3
                    if abs(a.center[u]-b.center[u])<1e-6 && abs(a.center[v]-b.center[v])<1e-6 { continue }
                }
                add(a.ref,(pointwiseMax(a.lo,b.lo)+pointwiseMin(a.hi,b.hi))/2,.warning,"overlap-"+b.ref.id,"machining regions overlap. Confirm that the depth and feature order are intentional.")
            } }
            if setup == nil,!regions.isEmpty { add(nil,part.size/2,.information,"setup","choose a saved CNC setup to check cutter diameter and cutting reach.") }
            if let setup,abs(part.size[part.materialAxes.t]-setup.measuredThickness)>1e-5 {
                add(nil,part.size/2,.information,"stock-thickness","this part needs \(Units.format(part.size[part.materialAxes.t],metric:project.metric)) stock; the saved setup measures \(Units.format(setup.measuredThickness,metric:project.metric)). Confirm the sheet-specific stock thickness.")
            }
            if part.trims.contains(where: { $0.suppressed != true }) || part.hasEdgeProfiles { add(nil,part.size/2,.warning,"angled-setup","angled end cuts/bevels require a separate setup; the flat file is their projected outline.") }
            if part.mesh != nil { add(nil,part.size/2,.warning,"3d-solid","the flat export shows this solid's projection. Use the STL/OBJ and a suitable 3D strategy for shaped surfaces.") }
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0.id).inserted }.sorted { $0.severity == $1.severity ? $0.message < $1.message : $0.severity > $1.severity }
    }
}
