import SceneKit
import Combine
import AppKit
import simd

final class PartNode {
    /// `root` carries the board's centre position and rotation; `body` holds the geometry in board-local coordinates.
    let root = SCNNode()
    let body = SCNNode()
    let edges = SCNNode()
    let featureProxies = SCNNode()
    var part: Part
    private(set) var polygons: [Geo.Poly] = []
    private var selected: Bool?
    private var highlightColor: NSColor?

    init(_ part: Part) {
        self.part = part
        body.name = part.id.uuidString
        body.categoryBitMask = SceneController.partMask
        edges.categoryBitMask = 1
        body.addChildNode(edges); body.addChildNode(featureProxies)
        root.addChildNode(body)
        rebuild()
        place()
    }

    func rebuild(section: SectionPlane? = nil, through: Int? = nil) {
        selected = nil
        featureProxies.childNodes.forEach { $0.removeFromParentNode() }
        let steps = through.map { Array(part.featureSteps.prefix(max(0,$0))) } ?? part.featureSteps
        if section == nil {
            for step in steps where step.kind != .trim {
                let polygons = part.toolPolygons(step)
                guard !polygons.isEmpty else { continue }
                let geometry = Geo.geometry(for:part,polygons:polygons)
                let material = SCNMaterial(); material.colorBufferWriteMask = []; material.writesToDepthBuffer = false; material.isDoubleSided = true
                geometry.materials = [material]
                let node = SCNNode(geometry:geometry); node.categoryBitMask = 4; node.name = part.id.uuidString + "|" + step.kind.rawValue + "|" + step.feature.uuidString
                featureProxies.addChildNode(node)
            }
        }
        if section != nil || through != nil {
            var polygons = through.map { FeatureReplay.polygons(part,through:$0) } ?? Geo.polys(for:part)
            if let section { polygons = Geo.sectionPolygons(part, section: section, polygons:polygons) }
            self.polygons = polygons
            body.geometry = Geo.geometry(for: part, polygons: polygons)
            var vertices: [SCNVector3] = [], indices: [UInt32] = []
            for polygon in polygons { for i in polygon.pts.indices {
                let base = UInt32(vertices.count)
                vertices += [vec(polygon.pts[i]), vec(polygon.pts[(i + 1) % polygon.pts.count])]; indices += [base, base + 1]
            } }
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
            geometry.materials = [Geo.lineMaterial(.black)]; edges.geometry = geometry
        } else {
            polygons = Geo.polys(for:part)
            body.geometry = Geo.geometry(for:part,polygons:polygons)
            edges.geometry = Geo.edgeGeometry(for:part,polygons:polygons)
        }
    }

    func place() {
        root.position = vec(part.center)
        let q = simd_quatd(part.rotMatrix)
        root.simdOrientation = simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
        body.position = vec(-part.size / 2)
    }

    func setSelected(_ on: Bool) {
        guard selected != on else { return }
        selected = on
        edges.geometry?.firstMaterial?.diffuse.contents = on ? NSColor.systemBlue : NSColor.black
        updateEmission()
    }

    func setHighlight(_ color: NSColor?) {
        highlightColor = color
        updateEmission()
    }

    private func updateEmission() {
        body.geometry?.firstMaterial?.emission.contents = highlightColor ?? (selected == true ? NSColor(deviceRed: 0.05, green: 0.12, blue: 0.3, alpha: 1) : NSColor.black)
    }
}

/// Owns the SceneKit scene: camera, grid, board nodes and tool overlays.
final class SceneController: ObservableObject {
    @Published private(set) var cameraRevision = 0
    weak var viewport: ModelView?
    static let partMask = 2

    let doc: Document
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let partsRoot = SCNNode()
    private var selOverlay: SCNNode?
    private var hoverOverlay: SCNNode?
    private let previewNode = SCNNode()
    private let measureNode = SCNNode()
    private let gizmoNode = SCNNode()
    private let snapNode = SCNNode()
    private let constructionNode = SCNNode()
    private var lastSection: SectionPlane?
    private var lastInspection: HistoryInspection?
    private let featureOverlay = SCNNode()
    private let reviewOverlay = SCNNode()
    private let ghostRoot = SCNNode()
    private var nodes: [UUID: PartNode] = [:]
    private var hover: FaceRef?
    private var snapPoint: SIMD3<Double>?
    private var snapRadius = 0.0
    private var lastSyncedPartsRevision: UInt64 = .max
    private var lastSyncedPreviewRevision: UInt64 = .max
    private var styledIDs: Set<UUID> = []
    private var highlightedIDs: Set<UUID> = []
    private var lastSelection: UUID?
    private var lastSelectedFace: FaceRef?
    private var lastSelectedFeature: FeatureRef?
    private var lastTool: Tool?
    private var lastGuides: [ConstructionGuide] = []
    private var lastDimensions: [ModelDimension] = []
    private var reviewPartsRevision: UInt64 = .max
    private var reviewMetric = false
    private var reviewSetup: CNCSetupProfile?
    private var reviewParameters: [DesignParameter] = []
    private var reviewIssues: [MachiningIssue] = []
    private var pendingCameraSave: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()

    var target = SIMD3<Double>(18, 12, 6)
    var distance = 110.0
    var yaw = 0.6
    var pitch = 0.5
    let fov = 35.0
    var ortho = false { didSet { updateCamera() } }

    init(doc: Document) {
        self.doc = doc
        scene.background.contents = NSColor(deviceRed: 0.80, green: 0.86, blue: 0.93, alpha: 1)
        [partsRoot, previewNode, measureNode, gizmoNode, snapNode, constructionNode, featureOverlay, reviewOverlay, ghostRoot].forEach { scene.rootNode.addChildNode($0) }
        buildLights()
        buildGrid()
        let cam = SCNCamera()
        cam.zNear = 1
        cam.zFar = 20000
        cam.fieldOfView = fov
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        if let preferences = doc.workspaceStore?.load() {
            target = preferences.target;distance = preferences.distance;yaw = preferences.yaw;pitch = preferences.pitch;ortho = preferences.ortho
        }
        updateCamera()

        doc.$parameterPreview.receive(on:RunLoop.main).sink { [weak self] _ in self?.sync() }.store(in:&bag)
        doc.$previewAffected.receive(on:RunLoop.main).sink { [weak self] _ in self?.rebuildHighlights() }.store(in:&bag)
        doc.$previewConflicts.receive(on:RunLoop.main).sink { [weak self] _ in self?.rebuildHighlights() }.store(in:&bag)
        doc.$historyInspection.receive(on:RunLoop.main).sink { [weak self] _ in self?.sync() }.store(in:&bag)
        doc.$selectedFeature.receive(on:RunLoop.main).sink { [weak self] _ in self?.updateSelection() }.store(in:&bag)
        doc.$showReviewHighlights.receive(on:RunLoop.main).sink { [weak self] _ in self?.rebuildHighlights() }.store(in:&bag)
        doc.$metric.receive(on:RunLoop.main).sink { [weak self] _ in
            guard let self, self.doc.showReviewHighlights && !self.reviewCacheIsCurrent else { return }
            self.rebuildHighlights()
        }.store(in:&bag)
        doc.$studio.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.sync(); self.updateConstruction()
            if self.doc.showReviewHighlights && !self.reviewCacheIsCurrent { self.rebuildHighlights() }
        }.store(in: &bag)
        doc.$parts.receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() }.store(in: &bag)
        doc.$selectedIDs.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            if self.doc.isolateSelection { self.updateVisibility(); self.rebuildHighlights() }
            self.updateSelection()
        }.store(in: &bag)
        doc.$isolateSelection.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateVisibility(); self?.rebuildHighlights() }.store(in: &bag)
        doc.$tool.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateSelection() }.store(in: &bag)
        doc.$selection.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateSelection() }.store(in: &bag)
        doc.$selectedFace.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateSelection() }.store(in: &bag)
    }

    // MARK: Scene setup

    private func buildLights() {
        func light(_ type: SCNLight.LightType, _ intensity: CGFloat, euler: SCNVector3 = SCNVector3Zero) {
            let n = SCNNode()
            n.light = SCNLight()
            n.light?.type = type
            n.light?.intensity = intensity
            n.eulerAngles = euler
            scene.rootNode.addChildNode(n)
        }
        light(.ambient, 550)
        light(.directional, 850, euler: SCNVector3(-0.9, 0.6, 0))
        light(.directional, 350, euler: SCNVector3(-0.5, -2.4, 0))
    }

    private func buildGrid() {
        var verts: [SCNVector3] = []
        var idx: [UInt32] = []
        let n = 20, step = 12.0, ext = Double(n) * step
        for i in -n...n where i != 0 {
            let p = Double(i) * step
            let b = UInt32(verts.count)
            verts += [SCNVector3(p, 0, -ext), SCNVector3(p, 0, ext), SCNVector3(-ext, 0, p), SCNVector3(ext, 0, p)]
            idx += [b, b + 1, b + 2, b + 3]
        }
        let grid = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                               elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        grid.materials = [Geo.lineMaterial(NSColor(deviceWhite: 0.62, alpha: 0.7))]
        scene.rootNode.addChildNode(SCNNode(geometry: grid))
        for (axis, color) in [(0, NSColor.systemRed), (1, NSColor.systemBlue), (2, NSColor.systemGreen)] {
            var a = SIMD3<Double>.zero, b = SIMD3<Double>.zero
            a[axis] = axis == 1 ? 0 : -ext; b[axis] = ext
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: [vec(a), vec(b)])],
                                elements: [SCNGeometryElement(indices: [0, 1] as [UInt32], primitiveType: .line)])
            g.materials = [Geo.lineMaterial(color)]
            scene.rootNode.addChildNode(SCNNode(geometry: g))
        }
    }

    func polygons(for id: UUID) -> [Geo.Poly] { nodes[id]?.polygons ?? [] }

    // MARK: Model sync

    private func sync() {
        let sectionChanged = lastSection != doc.studio.section
        let previousInspection = lastInspection
        let inspectionChanged = previousInspection != doc.historyInspection
        guard sectionChanged || inspectionChanged || lastSyncedPartsRevision != doc.partsRevision || lastSyncedPreviewRevision != doc.previewRevision else { return }
        lastSyncedPartsRevision = doc.partsRevision; lastSyncedPreviewRevision = doc.previewRevision
        lastSection = doc.studio.section; lastInspection = doc.historyInspection
        let displayedParts = doc.parameterPreview?.parts ?? doc.parts
        let ids = Set(displayedParts.map(\.id))
        for (id, pn) in nodes where !ids.contains(id) {
            pn.root.removeFromParentNode()
            nodes[id] = nil
        }
        for p in displayedParts {
            let through = doc.historyInspection?.part == p.id ? doc.historyInspection?.through : nil
            if let pn = nodes[p.id] {
                var rebuilt = false
                if pn.part != p {
                    let geometryChanged = pn.part.size != p.size || pn.part.cuts != p.cuts || pn.part.species != p.species
                        || pn.part.trims != p.trims || pn.part.profile != p.profile || pn.part.grainDirection != p.grainDirection || pn.part.mesh != p.mesh || pn.part.operations != p.operations || pn.part.patterns != p.patterns || pn.part.featureOrder != p.featureOrder
                    pn.part = p
                    if geometryChanged { pn.rebuild(section: doc.studio.section, through: through); pn.setSelected(doc.selectedIDs.contains(p.id)); rebuilt = true }
                    pn.place()
                }
                if !rebuilt && (sectionChanged || (inspectionChanged && (previousInspection?.part == p.id || doc.historyInspection?.part == p.id))) {
                    pn.rebuild(section: doc.studio.section, through: through)
                    pn.setSelected(doc.selectedIDs.contains(p.id))
                }
            } else {
                let pn = PartNode(p)
                if doc.studio.section != nil || through != nil { pn.rebuild(section: doc.studio.section, through: through) }
                pn.setSelected(doc.selectedIDs.contains(p.id))
                nodes[p.id] = pn
                partsRoot.addChildNode(pn.root)
            }
        }
        updateVisibility()
        updateSelection(force: true)
        rebuildHighlights()
    }

    private func updateVisibility() {
        for p in doc.parts { nodes[p.id]?.root.isHidden = !doc.isVisible(p) }
    }

    private func updateSelection(force: Bool = false) {
        let changed = styledIDs.symmetricDifference(doc.selectedIDs)
        for id in changed { nodes[id]?.setSelected(doc.selectedIDs.contains(id)) }
        let needsOverlay = force || !changed.isEmpty || lastSelection != doc.selection || lastSelectedFace != doc.selectedFace || lastSelectedFeature != doc.selectedFeature || lastTool != doc.tool
        styledIDs = doc.selectedIDs
        guard needsOverlay else { return }
        lastSelection = doc.selection; lastSelectedFace = doc.selectedFace; lastSelectedFeature = doc.selectedFeature; lastTool = doc.tool
        selOverlay?.removeFromParentNode(); selOverlay = nil
        if let f = doc.selectedFace, f.part == doc.selection {
            selOverlay = faceOverlay(f, color: NSColor.systemBlue.withAlphaComponent(0.4))
        }
        hoverOverlay?.removeFromParentNode(); hoverOverlay = nil
        hover = nil
        rebuildGizmo()
        rebuildFeatureOverlay()
    }

    private func rebuildGizmo() {
        gizmoNode.childNodes.forEach { $0.removeFromParentNode() }
        guard doc.tool == .move, let p = doc.selectedPart, doc.isVisible(p) else { return }
        let length = max(3, distance * 0.065)
        for (axis, color) in [(0, NSColor.systemRed), (1, NSColor.systemBlue), (2, NSColor.systemGreen)] {
            var end = p.center; end[axis] += length
            let material = Geo.lineMaterial(color)
            material.readsFromDepthBuffer = false
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: [vec(p.center), vec(end)])],
                elements: [SCNGeometryElement(indices: [0, 1] as [UInt32], primitiveType: .line)])
            geometry.materials = [material]
            let line = SCNNode(geometry: geometry); line.renderingOrder = 30
            gizmoNode.addChildNode(line)
            let cone = SCNCone(topRadius: 0, bottomRadius: length * 0.055, height: length * 0.18)
            cone.materials = [material]
            let handle = SCNNode(geometry: cone)
            handle.position = vec(end)
            if axis == 0 { handle.eulerAngles.z = -.pi / 2 }
            if axis == 2 { handle.eulerAngles.x = .pi / 2 }
            handle.name = String(axis); handle.categoryBitMask = 8; handle.renderingOrder = 30
            gizmoNode.addChildNode(handle)
        }
    }

    func showSnap(_ at: SIMD3<Double>?) {
        let radius = max(0.1, distance * 0.003)
        guard at != snapPoint || (at != nil && radius != snapRadius) else { return }
        snapPoint = at
        snapRadius = radius
        snapNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let at else { return }
        let sphere = SCNSphere(radius: radius)
        let material = Geo.lineMaterial(.systemOrange); material.readsFromDepthBuffer = false
        sphere.materials = [material]
        let marker = SCNNode(geometry: sphere); marker.position = vec(at); marker.renderingOrder = 40
        snapNode.addChildNode(marker)
    }

    /// A translucent overlay of the actual surface, including any curved outline or joinery.
    private func faceOverlay(_ f: FaceRef, color: NSColor) -> SCNNode? {
        guard let pn = nodes[f.part] else { return nil }
        let p = pn.part
        let a = f.axis, plane = f.positive ? p.size[f.axis] : 0
        var pts: [SIMD3<Double>] = [], indices: [UInt32] = []
        for poly in pn.polygons where (f.positive ? poly.n[a] : -poly.n[a]) > 1 - 1e-6 {
            guard poly.pts.allSatisfy({ abs($0[a] - plane) < 1e-6 }) else { continue }
            let base = UInt32(pts.count)
            pts += poly.pts.map { $0 + poly.n * 0.01 }
            for i in 1..<(poly.pts.count - 1) { indices += [base, base + UInt32(i), base + UInt32(i + 1)] }
        }
        guard !pts.isEmpty else { return nil }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pts.map(vec))],
                            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let m = Geo.lineMaterial(color)
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.renderingOrder = 10
        pn.body.addChildNode(n)
        return n
    }

    func setHover(_ f: FaceRef?) {
        guard f != hover else { return }
        hover = f
        hoverOverlay?.removeFromParentNode(); hoverOverlay = nil
        if let f { hoverOverlay = faceOverlay(f, color: NSColor.systemOrange.withAlphaComponent(0.35)) }
    }

    // MARK: Tool overlays

    func showPreview(origin: SIMD3<Double>, size: SIMD3<Double>) {
        previewNode.childNodes.forEach { $0.removeFromParentNode() }
        let b = SCNBox(width: size.x, height: size.y, length: size.z, chamferRadius: 0)
        let m = Geo.lineMaterial(NSColor.systemBlue.withAlphaComponent(0.45))
        b.materials = [m]
        let n = SCNNode(geometry: b)
        n.position = vec(origin + size / 2)
        previewNode.addChildNode(n)
    }

    func clearPreview() { previewNode.childNodes.forEach { $0.removeFromParentNode() } }

    func showMeasure(_ a: SIMD3<Double>, _ b: SIMD3<Double>) {
        clearMeasure()
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: [vec(a), vec(b)])],
                            elements: [SCNGeometryElement(indices: [0, 1] as [UInt32], primitiveType: .line)])
        let m = Geo.lineMaterial(.systemPurple)
        m.readsFromDepthBuffer = false
        g.materials = [m]
        let line = SCNNode(geometry: g)
        line.renderingOrder = 20
        measureNode.addChildNode(line)
        for p in [a, b] {
            let s = SCNSphere(radius: 0.4)
            s.materials = [m]
            let n = SCNNode(geometry: s)
            n.position = vec(p)
            n.renderingOrder = 20
            measureNode.addChildNode(n)
        }
    }

    func clearMeasure() { measureNode.childNodes.forEach { $0.removeFromParentNode() } }

    private func updateConstruction() {
        guard lastGuides != doc.studio.guides || lastDimensions != doc.studio.dimensions else { return }
        lastGuides = doc.studio.guides; lastDimensions = doc.studio.dimensions
        rebuildConstruction()
    }

    private func rebuildConstruction() {
        constructionNode.childNodes.forEach { $0.removeFromParentNode() }
        func line(_ a: SIMD3<Double>, _ b: SIMD3<Double>, color: NSColor) {
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: [vec(a), vec(b)])], elements: [SCNGeometryElement(indices: [0, 1] as [UInt32], primitiveType: .line)])
            geometry.materials = [Geo.lineMaterial(color)]
            constructionNode.addChildNode(SCNNode(geometry: geometry))
        }
        for guide in doc.studio.guides { line(guide.point - guide.direction * 500, guide.point + guide.direction * 500, color: .systemTeal) }
        for dimension in doc.studio.dimensions {
            line(dimension.a, dimension.b, color: .systemPurple)
            let text = SCNText(string: dimension.name + " " + doc.fmt(norm(dimension.b - dimension.a)), extrusionDepth: 0)
            text.font = .systemFont(ofSize: 1); text.flatness = 0.3; text.materials = [Geo.lineMaterial(.systemPurple)]
            let label = SCNNode(geometry: text); label.position = vec((dimension.a + dimension.b) / 2)
            label.constraints = [SCNBillboardConstraint()]; constructionNode.addChildNode(label)
        }
    }

    private func rebuildFeatureOverlay() {
        featureOverlay.childNodes.forEach { $0.removeFromParentNode() }
        guard let ref = doc.selectedFeature,let p = doc.part(ref.part),doc.isVisible(p) else { return }
        let polygons = p.toolPolygons(FeatureStep(kind:ref.kind,feature:ref.feature))
        guard !polygons.isEmpty else { return }
        let geometry = Geo.geometry(for:p,polygons:polygons)
        let material = Geo.lineMaterial(NSColor.systemOrange.withAlphaComponent(0.3)); material.isDoubleSided = true; material.writesToDepthBuffer = false
        geometry.materials = [material]
        let node = SCNNode(geometry:geometry); node.position = vec(p.center)
        let q = simd_quatd(p.rotMatrix)
        node.simdOrientation = simd_quatf(ix:Float(q.imag.x),iy:Float(q.imag.y),iz:Float(q.imag.z),r:Float(q.real))
        node.pivot = SCNMatrix4MakeTranslation(CGFloat(p.size.x/2),CGFloat(p.size.y/2),CGFloat(p.size.z/2))
        node.renderingOrder = 20; featureOverlay.addChildNode(node)
    }
    private func rebuildHighlights() {
        ghostRoot.childNodes.forEach { $0.removeFromParentNode() }
        reviewOverlay.childNodes.forEach { $0.removeFromParentNode() }
        if doc.parameterPreview != nil {
            for p in doc.parts where doc.previewAffected.contains(p.id) {
                let pn = PartNode(p); pn.root.opacity = 0.15; ghostRoot.addChildNode(pn.root)
            }
        }
        let issues: [MachiningIssue]
        if doc.showReviewHighlights {
            if !reviewCacheIsCurrent {
                reviewIssues = MachiningReview.issues(project:doc.project)
                reviewPartsRevision = doc.partsRevision
                reviewMetric = doc.metric
                reviewSetup = doc.studio.setupProfile
                reviewParameters = doc.studio.parameters ?? []
            }
            issues = reviewIssues
        } else { issues = [] }
        var marks = issues.map { ($0.part,$0.point) }
        marks += doc.previewConflicts.compactMap { id in doc.part(id).map { (id,$0.size/2) } }
        for (id,point) in marks {
            guard let p = doc.part(id),doc.isVisible(p) else { continue }
            let sphere = SCNSphere(radius:max(0.2,distance*0.004)); sphere.materials = [Geo.lineMaterial(.systemRed)]
            let marker = SCNNode(geometry:sphere); marker.position = vec(p.toWorld(point)); marker.renderingOrder = 30; reviewOverlay.addChildNode(marker)
        }
        let active = doc.previewAffected.union(doc.previewConflicts)
        for id in highlightedIDs.subtracting(active) { nodes[id]?.setHighlight(nil) }
        for id in active {
            nodes[id]?.setHighlight(doc.previewConflicts.contains(id) ? NSColor.systemRed.withAlphaComponent(0.35) : NSColor.systemOrange.withAlphaComponent(0.25))
        }
        highlightedIDs = active
    }

    private var reviewCacheIsCurrent: Bool {
        reviewPartsRevision == doc.partsRevision && reviewMetric == doc.metric &&
            reviewSetup == doc.studio.setupProfile && reviewParameters == (doc.studio.parameters ?? [])
    }

    // MARK: Camera

    func updateCamera() {
        SCNTransaction.begin();SCNTransaction.disableActions = true
        let cp = cos(pitch)
        let pos = target + distance * SIMD3(cp * sin(yaw), sin(pitch), cp * cos(yaw))
        cameraNode.position = vec(pos)
        cameraNode.look(at: vec(target))
        cameraNode.camera?.usesOrthographicProjection = ortho
        cameraNode.camera?.orthographicScale = distance * tan(fov * .pi / 360)
        SCNTransaction.commit()
        rebuildGizmo()
        cameraRevision += 1
        pendingCameraSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            guard let self, let store = self.doc.workspaceStore else { return }
            var p = store.load();p.target = self.target;p.distance = self.distance;p.yaw = self.yaw;p.pitch = self.pitch;p.ortho = self.ortho;store.save(p)
        }
        pendingCameraSave = save
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:save)
    }

    func screenPoint(_ world: SIMD3<Double>,size: CGSize) -> CGPoint? {
        if let viewport,viewport.bounds.width > 0,viewport.bounds.height > 0 {
            let p = viewport.projectPoint(vec(world))
            guard p.z >= 0,p.z <= 1 else { return nil }
            return CGPoint(x:Double(p.x)*size.width/viewport.bounds.width,y:(viewport.bounds.height-Double(p.y))*size.height/viewport.bounds.height)
        }
        let direction = SIMD3(cos(pitch)*sin(yaw),sin(pitch),cos(pitch)*cos(yaw))
        let right = SIMD3(cos(yaw),0,-sin(yaw)),up = cross(right,-direction)
        let relative = world-(target+distance*direction),depth = dot(relative,-direction)
        guard depth > 1,size.height > 0 else { return nil }
        let scale = Double(size.height)/(2*(ortho ? distance : depth)*tan(fov * .pi/360))
        return CGPoint(x:Double(size.width)/2+dot(relative,right)*scale,y:Double(size.height)/2-dot(relative,up)*scale)
    }

    func orbit(dx: Double, dy: Double) {
        yaw -= dx * 0.01
        pitch = min(1.553, max(-1.553, pitch + dy * 0.01))
        updateCamera()
    }

    func pan(dx: Double, dy: Double, viewHeight: Double) {
        let upp = 2 * distance * tan(fov * .pi / 360) / max(viewHeight, 1)
        let cp = cos(pitch)
        let fwd = -SIMD3(cp * sin(yaw), sin(pitch), cp * cos(yaw))
        let right = simdNormalize(SIMD3(-fwd.z, 0, fwd.x))
        let up = cross(right, fwd)
        target -= (right * dx + up * dy) * upp
        updateCamera()
    }

    func zoom(by factor: Double) {
        distance = min(5000, max(2, distance * factor))
        updateCamera()
    }

    func setView(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
        updateCamera()
    }

    func zoomExtents() {
        let visible = doc.parts.filter(doc.isVisible)
        guard !visible.isEmpty else { target = SIMD3(18, 12, 6); distance = 110; updateCamera(); return }
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in visible { let b = p.bounds; lo = pointwiseMin(lo, b.lo); hi = pointwiseMax(hi, b.hi) }
        target = (lo + hi) / 2
        distance = max(12, norm(hi - lo) / 2 / sin(fov * .pi / 360) * 1.1)
        updateCamera()
    }
}

func simdNormalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
    let n = norm(v)
    return n == 0 ? v : v / n
}

func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
