import Foundation

enum CuttingToolKind: String,Codable,CaseIterable { case endMill = "End mill",drill = "Drill",vBit = "V-bit / countersink",dovetail = "Dovetail" }
struct CuttingTool: Codable,Equatable,Identifiable {
    var id = UUID()
    var name = "1/4 inch end mill"
    var kind = CuttingToolKind.endMill
    var diameter = 0.25
    var fluteLength = 1.0
}
struct CNCSetupProfile: Codable,Equatable,Identifiable {
    var id = UUID()
    var name = "Plywood setup"
    var sheetLength = 96.0
    var sheetWidth = 48.0
    var measuredThickness = 0.75
    var species = Species.plywood
    var gap = 0.5
    var clearance = 0.005
    var registration = Registration()
    var metric = false
    var tools = [CuttingTool()]
    var activeTool: UUID? = nil
    var vcarveTemplate = ""
    var notes = ""
    var defaultTool: CuttingTool? { tools.first { $0.id == activeTool } ?? tools.first }
    func validate() throws {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              measuredThickness.isFinite,measuredThickness >= 1 / 32,clearance.isFinite,clearance >= 0,
              !tools.isEmpty,Set(tools.map(\.id)).count == tools.count else { throw ModelValidation.Failure(message:"Choose a setup name, positive measured thickness, and nonnegative clearance.") }
        if let message = ModelValidation.nesting(sheetL:sheetLength,sheetW:sheetWidth,gap:gap,registration:registration) { throw ModelValidation.Failure(message:message) }
        for tool in tools {
            guard tool.diameter.isFinite,tool.diameter > 0,tool.fluteLength.isFinite,tool.fluteLength > 0 else { throw ModelValidation.Failure(message:tool.name + ": diameter and flute length must be positive.") }
        }
        if let activeTool,!tools.contains(where: { $0.id == activeTool }) { throw ModelValidation.Failure(message:"The active cutter is missing from this setup.") }
    }
}
final class SetupProfileStore {
    let url: URL
    private(set) var loadError: String?
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("WoodShop").appendingPathComponent("CNC Setups.json")
    }
    private func decode(_ data: Data) throws -> [CNCSetupProfile] {
        let profiles = try JSONDecoder().decode([CNCSetupProfile].self,from:data)
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ModelValidation.Failure(message:"Saved setups contain duplicate identifiers.") }
        for profile in profiles { try profile.validate() }
        return profiles
    }
    func load() -> [CNCSetupProfile] {
        loadError = nil
        for candidate in [url,ProjectStorage.previousURL(url)] where FileManager.default.fileExists(atPath:candidate.path) {
            do {
                let profiles = try decode(Data(contentsOf:candidate))
                if candidate != url { loadError = "Recovered CNC setups from the previous version because the main file could not be read." }
                return profiles
            } catch { loadError = "CNC setups could not be loaded: " + error.localizedDescription }
        }
        return []
    }
    func save(_ profiles: [CNCSetupProfile]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(profiles); _ = try decode(data)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try ProjectStorage.write(data,to:url) { _ = try self.decode($0) }
        loadError = nil
    }
}
extension Document {
    @discardableResult func saveSetup(_ profile: CNCSetupProfile) -> Bool {
        do {
            try profile.validate()
            var saved = setupProfiles
            if let i = saved.firstIndex(where: { $0.id == profile.id }) { saved[i] = profile } else { saved.append(profile) }
            try setupProfileStore.save(saved); setupProfiles = saved
            status = "Saved CNC setup ‘\(profile.name)’ for future projects."
            return true
        } catch { status = error.localizedDescription; return false }
    }
    func deleteSetup(_ id: UUID) {
        do { let saved = setupProfiles.filter { $0.id != id }; try setupProfileStore.save(saved); setupProfiles = saved }
        catch { status = error.localizedDescription }
    }
    @discardableResult func activateSetup(_ profile: CNCSetupProfile) -> Bool {
        transaction {
            try profile.validate()
            sheetLength = profile.sheetLength; sheetWidth = profile.sheetWidth; nestGap = profile.gap
            metric = profile.metric; species = profile.species
            studio.registration = profile.registration; studio.setupProfile = profile
        }
    }
    func applyMeasuredThickness() {
        guard let profile = studio.setupProfile else { status = "Choose a CNC setup first."; return }
        if var parameters = studio.parameters,let i = parameters.firstIndex(where: { $0.name.lowercased() == "thickness" }) {
            parameters[i].expression = Units.decimal(profile.measuredThickness) + "in"
            _ = setParameters(parameters)
        } else {
            transaction {
                for i in parts.indices where selectedIDs.contains(parts[i].id) {
                    let old = parts[i]; parts[i].size[parts[i].materialAxes.t] = profile.measuredThickness; parts[i].adjustJoinery(from:old)
                }
            }
        }
    }
}
