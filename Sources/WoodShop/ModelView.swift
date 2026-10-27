import SceneKit
import SwiftUI
import AppKit

struct Pick {
    let id: UUID
    let face: FaceRef
    let point: SIMD3<Double>
    var planar = true
    var surface: Int? = nil
    var feature: FeatureRef? = nil
}

/// The 3D viewport: camera navigation plus all of the modelling tools.
final class ModelView: SCNView {
    var doc: Document!
    var ctrl: SceneController!

    private enum DragMode { case none, orbit, pan, move, pushPull, rect }
    private var mode = DragMode.none

    private var startParts: [Part] = []
    private var nearbyPartBounds: [Box] = []
    private var startPart: Part?
    private var pendingEdit: [Part] = []
    private var startHit = SIMD3<Double>.zero
    private var startMouse = CGPoint.zero
    private var pushFace: FaceRef?
    private var rectPlane: (axis: Int, value: Double, positive: Bool)?
    private var rectStart = SIMD3<Double>.zero
    private var inferencePartsRevision: UInt64 = .max
    private var inferenceSceneRevision: UInt64 = .max
    private var inferenceGuides: [ConstructionGuide] = []
    private var inferenceExcept: Set<UUID> = []
    private var inferenceSelectedIDs: Set<UUID> = []
    private var inferenceIsolated = false
    private var inferenceCache: [InferencePoint] = []
    private var inferenceScreenCache: [SIMD2<Double>] = []
    private var inferenceCameraRevision = -1
    private var inferenceViewSize = CGSize.zero
    private var tapeStart: SIMD3<Double>?
    private var secondaryStart = CGPoint.zero
    private var secondaryDidDrag = false

    override var acceptsFirstResponder: Bool { true }

    func connectActions() {
        doc.applyDistance = { [weak self] value in self?.applyExactDistance(value) }
        doc.cancelDrag = { [weak self] in self?.cancelOperation() }
        doc.finishDrag = { [weak self] in self?.finishOperation() }
    }

    private func beginEdit(_ part: Part, point: SIMD3<Double>, mouse: CGPoint, drag: DragMode) {
        doc.checkpoint()
        startPart = part
        startParts = doc.parts.filter { doc.selectedIDs.contains($0.id) }
        nearbyPartBounds = doc.parts.filter { !doc.selectedIDs.contains($0.id) && doc.isVisible($0) }.map { part in
            let bounds = part.bounds
            return Box(lo:bounds.lo,hi:bounds.hi)
        }
        pendingEdit = []
        startHit = point; startMouse = mouse; mode = drag
        doc.activeDrag = true; doc.exactDistance = ""
    }

    private func finishOperation() {
        if mode == .move || mode == .pushPull {
            let changed = pendingEdit.contains { doc.part($0.id) != $0 }
            let started = ProcessInfo.processInfo.systemUptime
            let committed = !changed || doc.applyPartChanges(pendingEdit)
            if changed { ctrl.recordEditCommit(ProcessInfo.processInfo.systemUptime - started) }
            ctrl.endEditPreview(committed:committed)
            doc.discardCheckpointIfUnchanged()
        }
        mode = .none; rectPlane = nil; startPart = nil; startParts = []; nearbyPartBounds = []
        pendingEdit = []
        doc.activeDrag = false; doc.exactDistance = ""
        ctrl.clearPreview(); ctrl.showSnap(nil)
    }

    private func cancelOperation() {
        if mode == .move || mode == .pushPull {
            pendingEdit = []
            doc.cancelCheckpoint()
            ctrl.endEditPreview(committed:false)
            mode = .none
        }
        mode = .none
        tapeStart = nil; ctrl.clearMeasure()
        finishOperation()
    }

    private func applyExactDistance(_ value: Double) {
        guard value.isFinite, let original = startPart else { return }
        if mode == .move {
            let axis = doc.axisLock ?? 0
            var origin = original.origin
            origin[axis] += value
            moveAssembly(to: origin)
            doc.status = "Moved \(doc.fmt(value)) along \(FaceRef.axisNames[axis])."
        } else if mode == .pushPull {
            dragPushPull(startMouse, exactAmount: value)
        }
        finishOperation()
        window?.makeFirstResponder(self)
    }

    private func moveAssembly(to origin: SIMD3<Double>) {
        guard let original = startPart else { return }
        let delta = origin - original.origin
        do {
            let values = try Parametric.values(doc.studio.parameters ?? [])
            for var part in startParts { part.origin += delta; try Parametric.validateBindings(part, values: values) }
        } catch { doc.status = error.localizedDescription; return }
        let moved = startParts.map { original -> Part in var p = original; p.origin += delta; return p }
        pendingEdit = moved
        ctrl.previewMove(moved)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Picking & rays

    private func pick(_ p: CGPoint) -> Pick? {
        let opts: [SCNHitTestOption: Any] = [.categoryBitMask: SceneController.partMask,
                                             .searchMode: SCNHitTestSearchMode.closest.rawValue]
        guard let r = hitTest(p, options: opts).first, let name = r.node.name,
              let id = UUID(uuidString: name) else { return nil }
        let n = [Double(r.localNormal.x), Double(r.localNormal.y), Double(r.localNormal.z)]
        let a = n.indices.max { abs(n[$0]) < abs(n[$1]) }!
        let part = doc.part(id)
        let coordinate = dvec(r.localCoordinates)[a]
        let onBlankFace = abs(coordinate - (n[a] > 0 ? (part?.size[a] ?? 0) : 0)) < 1e-6
        let planar = part?.profile == nil || (abs(n[a]) > 1 - 1e-6 && onBlankFace)
        var triangle = 0, surface: Int?
        let polys = ctrl.polygons(for:id)
        if part != nil { for (i, poly) in polys.enumerated() {
            let count = max(0, poly.pts.count - 2)
            if r.faceIndex >= triangle && r.faceIndex < triangle + count { surface = i; break }; triangle += count
        } }
        let owner = part.flatMap { FeaturePicking.onSurface(part:$0,polygon:surface.flatMap { polys.indices.contains($0) ? polys[$0] : nil },point:dvec(r.localCoordinates)) }
        return Pick(id: id, face: FaceRef(part: id, axis: a, positive: n[a] > 0), point: dvec(r.worldCoordinates), planar: planar, surface: surface, feature:owner)
    }

    private func pickedFeature(_ point: CGPoint) -> FeatureRef? {
        let body = hitTest(point,options:[.categoryBitMask:SceneController.partMask,.searchMode:SCNHitTestSearchMode.closest.rawValue]).first
        if let name = body?.node.name,let id = UUID(uuidString:name) { ctrl.ensureFeatureProxies(for:id) }
        let proxy = hitTest(point,options:[.categoryBitMask:4,.searchMode:SCNHitTestSearchMode.closest.rawValue]).first
        guard let proxy,norm(dvec(proxy.worldCoordinates)-dvec(ctrl.cameraNode.worldPosition)) <= (body.map { norm(dvec($0.worldCoordinates)-dvec(ctrl.cameraNode.worldPosition)) } ?? .infinity)+0.001,let name = proxy.node.name else { return nil }
        let fields = name.split(separator:"|")
        guard fields.count == 3,let id = UUID(uuidString:String(fields[0])),let kind = FeatureKind(rawValue:String(fields[1])),let feature = UUID(uuidString:String(fields[2])) else { return nil }
        return FeatureRef(part:id,kind:kind,feature:feature)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow,from:nil)
        if let feature = pickedFeature(point) {
            doc.selectFeature(feature)
            let menu = WorkspaceMenus.make(doc:doc,ctrl:ctrl,part:feature.part,feature:true)
            appendOverlappingParts(to:menu,at:point)
            return menu
        }
        if let hit = pick(point) {
            doc.focusContextPart(hit.id);doc.selectedFeature = hit.feature
            doc.selectedFace = hit.planar ? hit.face : nil;doc.selectedSurface = hit.surface
            let menu = WorkspaceMenus.make(doc:doc,ctrl:ctrl,part:hit.id,feature:hit.feature != nil)
            appendOverlappingParts(to:menu,at:point)
            return menu
        }
        return WorkspaceMenus.make(doc:doc,ctrl:ctrl,part:nil)
    }

    func overlappingParts(at point: CGPoint) -> [UUID] {
        let hits = hitTest(point,options:[.categoryBitMask:SceneController.partMask,.searchMode:SCNHitTestSearchMode.all.rawValue,.ignoreHiddenNodes:true])
        var seen: Set<UUID> = []
        let eye = dvec(ctrl.cameraNode.worldPosition)
        return hits.sorted(by: { (a: SCNHitTestResult,b: SCNHitTestResult) in norm(dvec(a.worldCoordinates)-eye) < norm(dvec(b.worldCoordinates)-eye) }).compactMap { hit in
            guard let name = hit.node.name,let id = UUID(uuidString:name),let part = doc.part(id),doc.isVisible(part),seen.insert(id).inserted else { return nil }
            return id
        }
    }
    private func appendOverlappingParts(to menu: NSMenu,at point: CGPoint) {
        let ids = overlappingParts(at:point)
        guard ids.count > 1 else { return }
        let submenu = NSMenu(title:"Select overlapping part")
        for id in ids {
            guard let part = doc.part(id) else { continue }
            let action = NativeMenuAction { [weak self] in self?.doc.select(id) }
            let row = NSMenuItem(title:ShopIdentity.label(part)+" "+part.name,action:#selector(NativeMenuAction.invoke(_:)),keyEquivalent:"")
            row.target = action;row.representedObject = action;row.state = doc.selection == id ? .on : .off;submenu.addItem(row)
        }
        let parent = NSMenuItem(title:"Select Overlapping Part",action:nil,keyEquivalent:"");parent.submenu = submenu
        menu.addItem(.separator());menu.addItem(parent)
    }

    /// Where the mouse ray meets the plane `coord[axis] == value`.
    private func intersect(axis: Int, value: Double, at p: CGPoint) -> SIMD3<Double>? {
        let a = dvec(unprojectPoint(SCNVector3(p.x, p.y, 0)))
        let b = dvec(unprojectPoint(SCNVector3(p.x, p.y, 1)))
        let d = b - a
        guard abs(d[axis]) > 1e-9 else { return nil }
        let t = (value - a[axis]) / d[axis]
        guard t > 0 else { return nil }
        return a + d * t
    }

    /// Model units moved along world direction `dir` for a mouse drag, via its on-screen direction.
    private func unitsAlong(dir: SIMD3<Double>, at world: SIMD3<Double>, mouseDelta: CGPoint) -> Double {
        let e = dir * 10
        let a = projectPoint(vec(world)), b = projectPoint(vec(world + e))
        let sx = Double(b.x - a.x), sy = Double(b.y - a.y)
        let len2 = sx * sx + sy * sy
        guard len2 > 1e-6 else { return 0 }
        return (Double(mouseDelta.x) * sx + Double(mouseDelta.y) * sy) / len2 * 10
    }

    private func unitsAlong(axis: Int, at world: SIMD3<Double>, mouseDelta: CGPoint) -> Double {
        var d = SIMD3<Double>.zero
        d[axis] = 1
        return unitsAlong(dir: d, at: world, mouseDelta: mouseDelta)
    }

    private func snapGrid(_ x: Double) -> Double { (x / doc.snap).rounded() * doc.snap }

    /// Snap a coordinate on `axis` to nearby board faces (other than `except`).
    private func snapToParts(_ x: Double, axis: Int, threshold: Double = 0.3) -> Double? {
        var best: (d: Double, v: Double)?
        for bb in nearbyPartBounds {
            for v in [bb.lo[axis], bb.hi[axis]] {
                let d = abs(v - x)
                if d < threshold && d < (best?.d ?? .infinity) { best = (d, v) }
            }
        }
        return best?.v
    }

    private func infer(_ screen: CGPoint, except: Set<UUID> = []) -> InferencePoint? {
        let selected = doc.isolateSelection ? doc.selectedIDs : []
        if inferencePartsRevision != doc.partsRevision || inferenceSceneRevision != ctrl.sceneRevision || inferenceGuides != doc.studio.guides ||
            inferenceExcept != except || inferenceIsolated != doc.isolateSelection || inferenceSelectedIDs != selected {
            let parts = doc.parts.filter { !except.contains($0.id) && doc.isVisible($0) }
            inferencePartsRevision = doc.partsRevision
            inferenceSceneRevision = ctrl.sceneRevision
            inferenceGuides = doc.studio.guides
            inferenceExcept = except
            inferenceIsolated = doc.isolateSelection
            inferenceSelectedIDs = selected
            inferenceCache = Inference.candidates(parts:parts,guides:inferenceGuides,polygons:{ self.ctrl.polygons(for:$0.id) })
            inferenceCameraRevision = -1
        }
        if inferenceCameraRevision != ctrl.cameraRevision || inferenceViewSize != bounds.size {
            inferenceCameraRevision = ctrl.cameraRevision
            inferenceViewSize = bounds.size
            inferenceScreenCache = inferenceCache.map { candidate in
                let p = projectPoint(vec(candidate.point))
                return SIMD2(Double(p.x), Double(p.y))
            }
        }
        return Inference.nearest(SIMD2(screen.x, screen.y), candidates: inferenceCache, projected: inferenceScreenCache)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        finishOperation()
        if ctrl.loadingProgress != nil { doc.status = "Building the model. Editing will be ready in a moment."; return }
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.control),let menu = menu(for:event) { NSMenu.popUpContextMenu(menu,with:event,for:self);return }
        if event.modifierFlags.contains(.option) {
            mode = event.modifierFlags.contains(.shift) ? .pan : .orbit
            return
        }
        if doc.parameterPreview != nil || doc.historyInspection != nil { doc.status = "Apply/discard the parameter preview or resume full feature history before editing the model."; return }
        if doc.tool == .move,
           let hit = hitTest(p, options: [.categoryBitMask: 8, .searchMode: SCNHitTestSearchMode.closest.rawValue]).first,
           let name = hit.node.name, let axis = Int(name), let part = doc.selectedPart {
            doc.axisLock = axis
            beginEdit(part, point: part.center, mouse: p, drag: .move)
            return
        }
        switch doc.tool {
        case .select:
            if let feature = pickedFeature(p),!event.modifierFlags.contains(.shift) {
                doc.selectFeature(feature);doc.selectedSurface = nil
                if event.clickCount >= 2 { doc.showFeatureEditor = true }
                return
            }
            if let h = pick(p) {
                if let feature = h.feature,!event.modifierFlags.contains(.shift) {
                    doc.selectFeature(feature)
                    if event.clickCount >= 2 { doc.showFeatureEditor = true }
                    return
                }
                doc.select(h.id, extending: event.modifierFlags.contains(.shift))
                doc.selectedFace = doc.selectedIDs.contains(h.id) && h.planar ? h.face : nil
                doc.status = "\(doc.part(h.id)?.name ?? "") — " + (h.planar ? "face \(h.face.label)" : "curved edge; use Edit curves to reshape.")
            } else { doc.selection = nil; doc.selectedFace = nil }
        case .move:
            guard let h = pick(p), let part = doc.part(h.id) else { return }
            if !doc.selectedIDs.contains(h.id) { doc.select(h.id) }
            doc.selectedFace = h.planar ? h.face : nil
            beginEdit(part, point: h.point, mouse: p, drag: .move)
        case .pushPull:
            guard let h = pick(p), let part = doc.part(h.id) else { return }
            guard h.planar else { doc.select(h.id); doc.selectedFace = nil; doc.status = "Use Edit curves to reshape a curved edge, or Push/Pull a flat face."; return }
            doc.select(h.id); doc.selectedFace = h.face
            pushFace = h.face
            beginEdit(part, point: h.point, mouse: p, drag: .pushPull)
        case .rectangle:
            var plane: (Int, Double, Bool)
            var start: SIMD3<Double>
            if let h = pick(p), let part = doc.part(h.id), !part.isRotated {
                guard h.planar else { doc.status = "Start a rectangle on a flat face or the ground."; return }
                let a = h.face.axis
                plane = (a, h.face.positive ? part.hi[a] : part.origin[a], h.face.positive)
                start = h.point
            } else if let g = intersect(axis: 1, value: 0, at: p) {
                plane = (1, 0, true); start = g
            } else { return }
            for i in 0..<3 { start[i] = i == plane.0 ? plane.1 : snapGrid(start[i]) }
            rectPlane = plane; rectStart = start
            mode = .rect
        case .tape:
            tapeClick(p)
        }
    }

    private func tapeClick(_ p: CGPoint) {
        var pt: SIMD3<Double>?
        if let h = pick(p), doc.part(h.id) != nil {
            pt = infer(p)?.point ?? h.point
        } else { pt = intersect(axis: 1, value: 0, at: p) }
        guard let pt else { return }
        if let s = tapeStart {
            let d = pt - s
            doc.lastMeasurement = [s, pt]
            ctrl.showMeasure(s, pt)
            doc.status = "Distance \(doc.fmt(norm(d)))   Δx \(doc.fmt(abs(d.x)))  Δy \(doc.fmt(abs(d.y)))  Δz \(doc.fmt(abs(d.z)))"
            tapeStart = nil
        } else {
            ctrl.clearMeasure()
            tapeStart = pt
            doc.status = "Click the second point."
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .none: break
        case .orbit: ctrl.orbit(dx: Double(event.deltaX), dy: Double(event.deltaY))
        case .pan: ctrl.pan(dx: Double(event.deltaX), dy: -Double(event.deltaY), viewHeight: Double(bounds.height))
        case .move: dragMove(event, p)
        case .pushPull: dragPushPull(p)
        case .rect: dragRect(p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if mode == .rect, let plane = rectPlane {
            ctrl.clearPreview()
            if let (origin, size) = rectGeometry(plane, current: p), size.x > 1e-6, size.y > 1e-6, size.z > 1e-6 {
                var board = Part(name: doc.nextName("Board"), origin: origin, size: size, species: doc.species)
                board.thicknessAxis = plane.axis
                board.grainDirection = (0..<3).filter { $0 != plane.axis }.max { size[$0] < size[$1] }
                doc.add(board)
                doc.status = "Board created — use Push/Pull (P) to change thickness."
            }
        }
        if mode == .move || mode == .pushPull {
            if let value = Units.parse(doc.exactDistance, bareIsMM: doc.metric) { applyExactDistance(value) }
            else { doc.status += " • Type a distance and Return, or Escape to cancel." }
        } else { finishOperation() }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self);finishOperation()
        secondaryStart = convert(event.locationInWindow,from:nil);secondaryDidDrag = false
    }
    override func rightMouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if hypot(point.x-secondaryStart.x,point.y-secondaryStart.y) > 4 { secondaryDidDrag = true }
        if secondaryDidDrag { mode = event.modifierFlags.contains(.shift) ? .pan : .orbit;mouseDragged(with:event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        mode = .none
        if !secondaryDidDrag,let menu = menu(for:event) { menu.popUp(positioning:nil,at:convert(event.locationInWindow,from:nil),in:self) }
    }
    override func otherMouseDown(with event: NSEvent) { finishOperation(); mode = event.modifierFlags.contains(.shift) ? .pan : .orbit }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mode = .none }

    override func mouseMoved(with event: NSEvent) {
        guard ctrl.loadingProgress == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if doc.tool == .select {
            if !doc.activeDrag { ctrl.showSnap(nil) }
            ctrl.setHover(nil)
            return
        }
        if doc.tool != .select,let inferred = infer(p, except: mode == .move ? doc.selectedIDs : []) { ctrl.showSnap(inferred.point) }
        else if !doc.activeDrag { ctrl.showSnap(nil) }
        if doc.tool == .tape { ctrl.setHover(nil) }
        else {
            let hovered = pick(p)
            ctrl.setHover(hovered?.planar == true ? hovered?.face : nil)
        }
    }

    // MARK: Tool drags

    private func dragMove(_ event: NSEvent, _ p: CGPoint) {
        guard let part = startPart else { return }
        var delta = SIMD3<Double>.zero
        if let axis = doc.axisLock {
            delta[axis] = unitsAlong(axis: axis, at: startHit, mouseDelta: CGPoint(x: p.x - startMouse.x, y: p.y - startMouse.y))
        } else if event.modifierFlags.contains(.shift) {
            delta.y = unitsAlong(axis: 1, at: startHit, mouseDelta: CGPoint(x: p.x - startMouse.x, y: p.y - startMouse.y))
        } else if let h = intersect(axis: 1, value: startHit.y, at: p) {
            delta = h - startHit
            delta.y = 0
        }
        if doc.axisLock == nil, !event.modifierFlags.contains(.shift), let snap = infer(p, except: doc.selectedIDs) {
            delta = snap.point - startHit
        }
        if let lock = doc.axisLock { for i in 0..<3 where i != lock { delta[i] = 0 } }
        var o = part.origin + delta
        var snapped = false
        for i in 0..<3 where delta[i] != 0 {
            o[i] = snapGrid(o[i])
            // Edge inference: line this board's faces up with its neighbours'.
            var best: (d: Double, shift: Double)?
            let pb = part.bounds, off = o[i] - part.origin[i]
            for ob in nearbyPartBounds {
                for mine in [pb.lo[i] + off, pb.hi[i] + off] {
                    for theirs in [ob.lo[i], ob.hi[i]] {
                        let d = abs(theirs - mine)
                        if d < 0.3 && d < (best?.d ?? .infinity) { best = (d, theirs - mine) }
                    }
                }
            }
            if let b = best, delta[i] != 0 { o[i] += b.shift; snapped = true }
        }
        moveAssembly(to: o)
        ctrl.showSnap(snapped ? startHit + o - part.origin : nil)
        doc.status = "At X \(doc.fmt(o.x))  Y \(doc.fmt(o.y))  Z \(doc.fmt(o.z))" + (snapped ? "  • snapped to edge" : "")
            + (doc.axisLock.map { "  • locked \(FaceRef.axisNames[$0])" } ?? "")
    }

    private func dragPushPull(_ p: CGPoint, exactAmount: Double? = nil) {
        guard let part = startPart, let f = pushFace else { return }
        let a = f.axis
        guard !doc.links.contains(where: { $0.target == part.id && $0.targetAxis == a }) && !(part.bindings ?? []).contains(where: { $0.target == .size && $0.axis == a }) else {
            doc.status = "This dimension is driven. Edit its parameter/source board, or unlink the expression first."; return
        }
        var dir = SIMD3<Double>.zero
        dir[a] = 1
        let amount = exactAmount ?? unitsAlong(dir: part.dirToWorld(dir), at: startHit,
                                mouseDelta: CGPoint(x: p.x - startMouse.x, y: p.y - startMouse.y))
        let oldSize = part.size[a]
        let target = (f.positive ? oldSize : 0) + amount          // face position in the board's old local frame
        var newSize: Double
        if exactAmount != nil {
            newSize = f.positive ? oldSize + amount : oldSize - amount
        } else if part.isRotated {
            newSize = snapGrid(f.positive ? target : oldSize - target)
        } else {
            var w = snapGrid(part.origin[a] + target)
            if let s = snapToParts(part.origin[a] + target, axis: a) { w = s }
            newSize = f.positive ? w - part.origin[a] : part.hi[a] - w
        }
        if exactAmount != nil, newSize < 1 / 32 {
            doc.status = "The resulting board must be at least 1/32 inch thick."; return
        }
        newSize = max(newSize, 1 / 32)
        var np = part
        np.size[a] = newSize
        if part.resizeJoinery == true {
            for i in np.cuts.indices {
                np.cuts[i].lo[a] *= newSize / oldSize
                np.cuts[i].hi[a] *= newSize / oldSize
            }
        } else if !f.positive {
            // Cuts are measured from the min face, so slide them to stay put relative to the far face.
            let d = newSize - oldSize
            for i in np.cuts.indices where !(np.cuts[i].faceAxis == a && np.cuts[i].facePositive == false) {
                np.cuts[i].lo[a] += d; np.cuts[i].hi[a] += d
            }
        } else {
            let d = newSize - oldSize
            for i in np.cuts.indices where np.cuts[i].faceAxis == a && np.cuts[i].facePositive == true {
                np.cuts[i].lo[a] += d; np.cuts[i].hi[a] += d
            }
        }
        // Keep the opposite face where it was in the world.
        func fixedPoint(_ q: Part) -> SIMD3<Double> {
            var l = q.size / 2
            l[a] = f.positive ? 0 : q.size[a]
            return q.toWorld(l)
        }
        np.origin += fixedPoint(part) - fixedPoint(np)
        // Each drag frame derives geometry from the original board.
        if let message = ModelValidation.axes(np) { doc.status = message; return }
        pendingEdit = [np]
        ctrl.previewPart(np)
        var faceCenter = np.size / 2
        faceCenter[a] = f.positive ? np.size[a] : 0
        ctrl.showSnap(exactAmount == nil ? np.toWorld(faceCenter) : nil)
        doc.status = "\(FaceRef.axisNames[a]) size: \(doc.fmt(np.size[a]))"
    }

    private func rectGeometry(_ plane: (axis: Int, value: Double, positive: Bool), current p: CGPoint)
        -> (SIMD3<Double>, SIMD3<Double>)? {
        guard var cur = intersect(axis: plane.axis, value: plane.value, at: p) else { return nil }
        if let inference = infer(p), abs(inference.point[plane.axis] - plane.value) < 1e-5 { cur = inference.point }
        for i in 0..<3 { cur[i] = i == plane.axis ? plane.value : snapGrid(cur[i]) }
        var lo = pointwiseMin(rectStart, cur), hi = pointwiseMax(rectStart, cur)
        let t = doc.rectThickness
        if plane.positive { hi[plane.axis] = plane.value + t } else { lo[plane.axis] = plane.value - t; hi[plane.axis] = plane.value }
        return (lo, hi - lo)
    }

    private func dragRect(_ p: CGPoint) {
        guard let plane = rectPlane, let (o, s) = rectGeometry(plane, current: p) else { return }
        let dims = (0..<3).filter { $0 != plane.axis }.map { doc.fmt(s[$0]) }.joined(separator: " × ")
        doc.status = "Rectangle \(dims)"
        if s.x > 1e-6 && s.y > 1e-6 && s.z > 1e-6 { ctrl.showPreview(origin: o, size: s) } else { ctrl.clearPreview() }
    }

    // MARK: Trackpad / wheel

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            if event.modifierFlags.contains(.shift) {
                ctrl.pan(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), viewHeight: Double(bounds.height))
            } else if event.modifierFlags.contains(.command) {
                ctrl.zoom(by: exp(-Double(event.scrollingDeltaY) * 0.01))
            } else {
                ctrl.orbit(dx: Double(event.scrollingDeltaX) * 0.5, dy: Double(-event.scrollingDeltaY) * 0.5)
            }
        } else {
            ctrl.zoom(by: exp(-Double(event.scrollingDeltaY) * 0.08))
        }
    }

    override func magnify(with event: NSEvent) { ctrl.zoom(by: 1 - Double(event.magnification)) }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with:event);return }
        if doc.activeDrag, let chars = event.charactersIgnoringModifiers,
           chars.allSatisfy({ "0123456789.- /\"'mcin".contains($0) }), !chars.isEmpty {
            doc.exactDistance += chars
            return
        }
        if doc.activeDrag, event.keyCode == 36,
           let value = Units.parse(doc.exactDistance, bareIsMM: doc.metric) {
            applyExactDistance(value); return
        }
        if doc.activeDrag, event.keyCode == 51, !doc.exactDistance.isEmpty {
            doc.exactDistance.removeLast(); return
        }
        switch event.keyCode {
        case 53: // esc
            let editing = mode == .move || mode == .pushPull || mode == .rect
            cancelOperation()
            if !editing { doc.selection = nil; doc.selectedFace = nil }
            return
        case 51, 117: WorkspaceAction.delete.run(doc:doc,ctrl:ctrl); return
        case 123, 124, 125, 126: arrow(event); return
        default: break
        }
        if event.keyCode == 36,!doc.activeDrag { WorkspaceAction.rename.run(doc:doc,ctrl:ctrl);return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": doc.tool = .select
        case "h": (event.modifierFlags.contains(.shift) ? WorkspaceAction.showAll : .hide).run(doc:doc,ctrl:ctrl)
        case "f": (doc.selectedIDs.isEmpty ? WorkspaceAction.fitAll : .fitSelection).run(doc:doc,ctrl:ctrl)
        case "m": doc.tool = .move
        case "p": doc.tool = .pushPull
        case "r": doc.tool = .rectangle
        case "t": doc.tool = .tape
        default: super.keyDown(with: event)
        }
    }

    private func arrow(_ event: NSEvent) {
        if mode == .move {
            switch event.keyCode {
            case 124: doc.axisLock = 0
            case 123: doc.axisLock = 2
            case 126: doc.axisLock = 1
            default: doc.axisLock = nil
            }
            return
        }
        guard doc.selection != nil else { return }
        let step = doc.snap * (event.modifierFlags.contains(.shift) ? 8 : 1)
        var d = SIMD3<Double>.zero
        let alt = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 124: d.x = step
        case 123: d.x = -step
        case 126: if alt { d.y = step } else { d.z = -step }
        default: if alt { d.y = -step } else { d.z = step }
        }
        doc.checkpoint()
        for p in doc.parts where doc.selectedIDs.contains(p.id) { doc.update(p.id) { $0.origin += d } }
    }
}

struct ViewportView: NSViewRepresentable {
    let doc: Document
    let ctrl: SceneController

    func makeNSView(context: Context) -> ModelView {
        let v = ModelView(frame: .zero)
        v.doc = doc
        v.ctrl = ctrl
        ctrl.viewport = v
        v.connectActions()
        v.scene = ctrl.scene
        v.pointOfView = ctrl.cameraNode
        v.antialiasingMode = doc.parts.count > 400 ? .multisampling2X : .multisampling4X
        v.showsStatistics = ctrl.renderStatisticsVisible
        v.allowsCameraControl = false
        v.autoenablesDefaultLighting = false
        return v
    }

    func updateNSView(_ nsView: ModelView, context: Context) {
        let quality: SCNAntialiasingMode = doc.parts.count > 400 ? .multisampling2X : .multisampling4X
        if nsView.antialiasingMode != quality { nsView.antialiasingMode = quality }
    }
}
