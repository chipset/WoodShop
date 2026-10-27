import Foundation
import AppKit
import SwiftUI

struct WorkspacePreferences: Codable, Equatable {
    var partsVisible = true
    var inspectorVisible = true
    var dimensionsVisible = true
    var partFilter = "All"
    var partSearch = ""
    var metric = false
    var setupID: UUID?
    var activeSetup: CNCSetupProfile?
    var target = SIMD3<Double>(18,12,6)
    var distance = 110.0
    var yaw = 0.6
    var pitch = 0.5
    var ortho = false
}

final class WorkspacePreferencesStore {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> WorkspacePreferences {
        guard let data = defaults.data(forKey:"WoodShop.workspace.v1"),
              let value = try? JSONDecoder().decode(WorkspacePreferences.self,from:data),
              ModelValidation.finite(value.target),value.distance.isFinite,(1...20000).contains(value.distance),
              value.yaw.isFinite,value.pitch.isFinite,abs(value.pitch) <= .pi/2 else { return WorkspacePreferences() }
        return value
    }
    func save(_ preferences: WorkspacePreferences) {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data,forKey:"WoodShop.workspace.v1") }
    }
}

extension Document {
    func persistWorkspace() {
        guard let workspaceStore else { return }
        var p = workspaceStore.load()
        p.partsVisible = showPartsSidebar;p.inspectorVisible = showInspector;p.dimensionsVisible = showEditableDimensions
        p.partFilter = partFilter;p.partSearch = partSearch;p.metric = metric;p.setupID = studio.setupProfile?.id;p.activeSetup = studio.setupProfile
        workspaceStore.save(p)
    }
}

/// Let AppKit restore divider positions independently of project contents.
struct WorkspaceSplitRestoration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView,context: Context) {
        DispatchQueue.main.async {
            func split(in node: NSView) -> NSSplitView? {
                if let value = node as? NSSplitView { return value }
                for child in node.subviews { if let value = split(in:child) { return value } }
                return nil
            }
            if let root = view.window?.contentView,let split = split(in:root),split.autosaveName == nil { split.autosaveName = "WoodShop.workspace.split" }
            if view.window?.frameAutosaveName.isEmpty == true { view.window?.setFrameAutosaveName("WoodShop.workspace.window") }
        }
    }
}
