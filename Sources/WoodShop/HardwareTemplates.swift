import Foundation

struct HardwareTemplate: Codable,Equatable,Identifiable {
    var id = UUID()
    var name = "Custom hardware"
    var pattern = DrillingPattern()
    var quantityPerUse = 1
    var unitCost = 0.0
    var notes = "Verify hole sizes, offsets, and depth against your hardware before machining."
    var manufacturer: String? = nil
    var partNumber: String? = nil
    var sourceURL: String? = nil
    var verifiedDimensions: String? = nil
    func validate() throws {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,quantityPerUse>0,quantityPerUse<=1000,unitCost.isFinite,unitCost>=0,
              (0..<3).contains(pattern.axis),pattern.diameter.isFinite,pattern.diameter>0,pattern.depth.isFinite,pattern.depth>0,
              (1...100).contains(pattern.columns),(1...100).contains(pattern.rows),pattern.columns*pattern.rows<=100 else { throw ModelValidation.Failure(message:"Give the hardware a name, positive hole dimensions, and up to 100 holes per pattern.") }
    }
    static var examples: [HardwareTemplate] {
        var handle = HardwareTemplate();handle.id = UUID(uuidString:"11111111-1111-4111-8111-111111111111")!;handle.name = "Handle · editable hole spacing"
        handle.pattern.columns = 2;handle.pattern.rows = 1;handle.pattern.pitch.x = 128/25.4;handle.pattern.diameter = 5/25.4;handle.pattern.through = true;handle.pattern.placement = .fixed
        var pins = HardwareTemplate();pins.id = UUID(uuidString:"22222222-2222-4222-8222-222222222222")!;pins.name = "Shelf pins · editable 32 mm grid"
        pins.pattern.columns = 8;pins.pattern.rows = 2;pins.pattern.pitch = SIMD2(32/25.4,8);pins.pattern.diameter = 5/25.4;pins.pattern.depth = 0.375;pins.pattern.placement = .fixed
        var slide = HardwareTemplate();slide.id = UUID(uuidString:"33333333-3333-4333-8333-333333333333")!;slide.name = "Drawer slide · enter mounting positions"
        slide.pattern.columns = 3;slide.pattern.pitch.x = 4;slide.pattern.diameter = 0.125;slide.pattern.depth = 0.375;slide.pattern.placement = .fixed
        var cup = HardwareTemplate();cup.id = UUID(uuidString:"44444444-4444-4444-8444-444444444444")!
        cup.name = "Blum 71B3550 · CLIP top BLUMOTION cup";cup.manufacturer = "Blum";cup.partNumber = "71B3550"
        cup.sourceURL = "https://www.blum.com/us/en/products/hingesystems/clip-top-blumotion/assembly/"
        cup.verifiedDimensions = "35 mm cup diameter; 13 mm minimum bore depth (Blum)."
        cup.pattern.diameter = 35/25.4;cup.pattern.depth = 13/25.4;cup.pattern.origin = SIMD2(22.5/25.4,4)
        cup.pattern.placement = .fixed
        cup.notes = "Screw-on hinge cup only. 5 mm edge setback and 4 in end position are editable design choices, not fixed Blum specifications. Select the door face and confirm the U edge, overlay, plate, door thickness, and screw fixing before machining."
        var plate = HardwareTemplate();plate.id = UUID(uuidString:"55555555-5555-4555-8555-555555555555")!
        plate.name = "Blum 173H7100 · 37/32 plate centers";plate.manufacturer = "Blum";plate.partNumber = "173H7100"
        plate.sourceURL = "https://publications.blum.com/2024/catalogue/en/152/"
        plate.verifiedDimensions = "Cruciform plate fixing line 37 mm from cabinet front; hole-center pitch 32 mm (Blum)."
        plate.pattern.columns = 1;plate.pattern.rows = 2;plate.pattern.pitch.y = 32/25.4;plate.pattern.origin = SIMD2(37/25.4,4)
        plate.pattern.diameter = 2.5/25.4;plate.pattern.depth = 8/25.4;plate.pattern.placement = .fixed
        plate.notes = "Reference hole centers. 2.5 mm pilot diameter, 8 mm depth, and 4 in end position are editable starting values, not specified by Blum. Confirm screw, stock, mounting face, overlay, and edge datum before machining."
        return [cup,plate,handle,pins,slide]
    }
}
final class HardwareTemplateStore {
    let url: URL
    init(url: URL? = nil) { self.url = url ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WoodShop/Hardware templates.json") }
    func load() -> [HardwareTemplate] {
        for candidate in [url,ProjectStorage.previousURL(url)] {
            if let data = try? Data(contentsOf:candidate),let templates = try? JSONDecoder().decode([HardwareTemplate].self,from:data),templates.allSatisfy({ (try? $0.validate()) != nil }),Set(templates.map(\.id)).count == templates.count { return templates }
        }
        return []
    }
    func save(_ templates: [HardwareTemplate]) throws {
        for template in templates { try template.validate() }
        guard Set(templates.map(\.id)).count == templates.count else { throw ModelValidation.Failure(message:"Duplicate hardware template identifiers.") }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try ProjectStorage.write(JSONEncoder().encode(templates),to:url) { data in let old = try JSONDecoder().decode([HardwareTemplate].self,from:data);for template in old { try template.validate() } }
    }
}
extension Document {
    @discardableResult func applyHardwareTemplate(_ template: HardwareTemplate,parts ids: Set<UUID>) -> Bool {
        guard !workspaceInspectionOnly,!ids.isEmpty else { return false }
        return transaction {
            try template.validate()
            var library = studio.hardwareTemplates ?? [];library.removeAll { $0.id == template.id };library.append(template);studio.hardwareTemplates = library
            for i in parts.indices where ids.contains(parts[i].id) && parts[i].hardware != true {
                var pattern = template.pattern;pattern.id = UUID();pattern.name = template.name;pattern.hardwareTemplateID = template.id
                let face = selectedFace?.part == parts[i].id ? selectedFace : nil
                pattern.axis = face?.axis ?? parts[i].materialAxes.t;pattern.positive = face?.positive ?? parts[i].cncTopPositive ?? true
                parts[i].patterns = (parts[i].patterns ?? [])+[pattern];parts[i].featureOrder = parts[i].featureSteps
                parts[i].component = nil
            }
        }
    }
}
