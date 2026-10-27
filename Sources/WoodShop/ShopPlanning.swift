import Foundation

enum BandEdge: String,Codable,CaseIterable,Identifiable {
    case lengthMin = "End 1",lengthMax = "End 2",widthMin = "Edge 1",widthMax = "Edge 2"
    var id: String { rawValue }
}
struct PartShopData: Codable,Equatable {
    var bandedEdges: [BandEdge] = []
    var bandThickness = 0.04
    var roughAllowance = 0.0
    var grainMatchGroup = ""
    var grainMatchOrder: Int? = nil
    func validate() throws {
        guard bandThickness.isFinite,bandThickness>=0,roughAllowance.isFinite,roughAllowance>=0,
              Set(bandedEdges).count == bandedEdges.count,grainMatchOrder.map({ $0 > 0 && $0 <= 10_000 && !grainMatchGroup.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) ?? true else { throw ModelValidation.Failure(message:"Use finite, nonnegative banding dimensions; a grain-match order also needs a group name.") }
    }
    func finished(_ part: Part) -> SIMD3<Double> {
        var size = part.size;let axes = part.materialAxes
        size[axes.l] += Double(bandedEdges.filter { $0 == .lengthMin || $0 == .lengthMax }.count)*bandThickness
        size[axes.w] += Double(bandedEdges.filter { $0 == .widthMin || $0 == .widthMax }.count)*bandThickness
        return size
    }
    func bandLength(_ part: Part) -> Double {
        let axes = part.materialAxes
        return bandedEdges.reduce(0) { $0+part.size[$1 == .lengthMin || $1 == .lengthMax ? axes.w : axes.l] }
    }
}
struct MaterialRate: Codable,Equatable,Identifiable {
    var species: Species
    var perSquareFoot = 0.0
    var perBoardFoot = 0.0
    var bandPerFoot: Double? = nil
    var id: String { species.rawValue }
}
struct SheetStock: Codable,Equatable,Identifiable {
    var id = UUID()
    var name = "Measured offcut"
    var species = Species.plywood
    var thickness = 0.75
    var length = 48.0
    var width = 24.0
    var cost: Double? = nil
    var enabled = true
    func validate() throws {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,thickness.isFinite,thickness>=1/32,
              length.isFinite,width.isFinite,length>0,width>0,cost.map({$0.isFinite && $0>=0}) ?? true else { throw ModelValidation.Failure(message:"Offcuts need a name, measured dimensions and thickness, and a nonnegative cost.") }
    }
}
enum ShopPlanning {
    static func grainMatchMap(_ project: Project,layout: Nesting.Result) -> String {
        func q(_ value: String) -> String { "\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
        var lines = ["Group,Order,Part ID,Part name,Sheet,Stock,Cross-grain start,Cross-grain end,Along-grain start,Along-grain end,Units"]
        let matched = layout.placed.filter { !($0.part.grainMatchGroup ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        for placed in matched.sorted(by: { $0.sheet == $1.sheet ? $0.y < $1.y : $0.sheet < $1.sheet }) {
            let part = placed.part,b = part.footprint
            let x = placed.x-layout.sheets[placed.sheet].x
            let scale = project.metric ? 25.4 : 1.0
            let row = [q(part.grainMatchGroup ?? ""),part.grainMatchOrder.map(String.init) ?? "",q(part.shopLabel ?? ""),q(part.name),String(placed.sheet+1),q(layout.stock(at:placed.sheet)?.name ?? "Full sheet"),Units.decimal((placed.y+b.lo.y)*scale),Units.decimal((placed.y+b.hi.y)*scale),Units.decimal((x+b.lo.x)*scale),Units.decimal((x+b.hi.x)*scale),project.metric ? "mm" : "in"]
            lines.append(row.joined(separator:","))
        }
        return lines.joined(separator:"\r\n")+"\r\n"
    }
    static func schedule(_ project: Project) -> String {
        func quote(_ text: String) -> String { "\""+text.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
        var lines = ["Part ID,Name,Material,Core length,Core width,Core thickness,Finished length,Finished width,Rough length,Rough width,Edge banding,Grain match group,Grain match order"]
        for p in project.parts where p.hardware != true {
            let data = p.shop ?? PartShopData(),axes = p.materialAxes,finished = data.finished(p)
            func dim(_ value: Double) -> String { quote(Units.format(value,metric:project.metric)) }
            lines.append([quote(ShopIdentity.label(p)),quote(p.name),quote(p.species.rawValue),dim(p.size[axes.l]),dim(p.size[axes.w]),dim(p.size[axes.t]),dim(finished[axes.l]),dim(finished[axes.w]),dim(p.size[axes.l]+2*data.roughAllowance),dim(p.size[axes.w]+2*data.roughAllowance),quote(data.bandedEdges.map(\.rawValue).joined(separator:" / ")),quote(data.grainMatchGroup),data.grainMatchOrder.map(String.init) ?? ""].joined(separator:","))
        }
        return lines.joined(separator:"\r\n")+"\r\n"
    }
    static func estimate(_ project: Project,layout: Nesting.Result) -> (lumber: Double,sheets: Double,hardware: Double,banding: Double,bandLength: Double) {
        let rates = project.studio?.materialRates ?? [],parts = project.parts.filter { $0.hardware != true }
        let waste = project.studio?.lumberWaste ?? 0.15
        let lumber = parts.filter { !$0.species.isSheet }.reduce(0.0) { total,p in
            let rate = rates.first { $0.species == p.species }?.perBoardFoot ?? 0
            let rough = p.shop?.roughAllowance ?? 0,axes = p.materialAxes
            let boardFeet = (p.size[axes.l]+2*rough)*(p.size[axes.w]+2*rough)*p.size[axes.t]/144
            return total+boardFeet*rate*(1+waste)
        }
        let sheets = layout.sheets.indices.reduce(0.0) { total,index in
            guard let stock = layout.stock(at:index),stock.species.isSheet else { return total }
            let cost = stock.cost ?? stock.length*stock.width/144*(rates.first { $0.species == stock.species }?.perSquareFoot ?? 0)
            return total+cost
        }
        let templates = project.studio?.hardwareTemplates ?? []
        let hardware = parts.reduce(0.0) { total,p in total+(p.patterns ?? []).reduce(0.0) { sum,pattern in
            guard let id = pattern.hardwareTemplateID,let template = templates.first(where: { $0.id == id }) else { return sum }
            return sum+template.unitCost*Double(template.quantityPerUse)
        } }
        let bandLength = parts.reduce(0) { $0+($1.shop?.bandLength($1) ?? 0) }
        let banding = parts.reduce(0.0) { total,p in total+(p.shop?.bandLength(p) ?? 0)/12*(rates.first { $0.species == p.species }?.bandPerFoot ?? 0) }
        return (lumber,sheets,hardware,banding,bandLength)
    }
    static func hardwareSchedule(_ project: Project) -> String {
        let templates = project.studio?.hardwareTemplates ?? []
        var lines = ["Hardware,Quantity,Unit cost,Manufacturer,Part number,Documented dimensions,Source,Notes"]
        for template in templates {
            var allPatterns: [DrillingPattern] = []
            for part in project.parts { allPatterns += part.patterns ?? [] }
            let uses: Int = allPatterns.filter { $0.hardwareTemplateID == template.id }.count
            guard uses>0 else { continue }
            func q(_ text: String) -> String { "\""+text.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
            lines.append([q(template.name),String(uses*template.quantityPerUse),Units.decimal(template.unitCost),q(template.manufacturer ?? ""),q(template.partNumber ?? ""),q(template.verifiedDimensions ?? ""),q(template.sourceURL ?? ""),q(template.notes)].joined(separator:","))
        }
        return lines.joined(separator:"\r\n")+"\r\n"
    }
}
