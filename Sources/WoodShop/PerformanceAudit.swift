import Foundation

struct PerformanceAudit {
    struct Measure: Codable {
        var name: String
        var seconds: Double
        var targetSeconds: Double
        var error: String? = nil
        var passed: Bool { error == nil && seconds <= targetSeconds }
    }
    struct Report: Codable {
        var partCount: Int
        var processorCount: Int
        var measures: [Measure]
        var summary: String {
            let heading = "Current project: \(partCount) parts · \(processorCount) logical processors. Local working targets scale from a 500-part project."
            return ([heading]+measures.map { item in
                let status = item.passed ? "PASS" : "OVER TARGET"
                return "\(status) · \(item.name): \(String(format:"%.3f",item.seconds)) s / \(String(format:"%.1f",item.targetSeconds)) s target"+(item.error.map { " · "+$0 } ?? "")
            }).joined(separator:"\n")
        }
    }
    static func run(_ project: Project) -> Report {
        let count = project.parts.filter { $0.hardware != true }.count
        let factor = max(1,Double(count)/500)
        var measures: [Measure] = []
        func measure(_ name: String,target: Double,_ body: () throws -> Void) {
            let start = ProcessInfo.processInfo.systemUptime
            var failure: String? = nil
            do { try body() } catch { failure = error.localizedDescription }
            measures.append(Measure(name:name,seconds:ProcessInfo.processInfo.systemUptime-start,targetSeconds:target*factor,error:failure))
        }
        measure("Project validation",target:2) { try ModelValidation.validate(project) }
        measure("Parametric regeneration",target:5) {
            var parts = project.parts
            try Regeneration.rebuild(parts:&parts,links:project.links,studio:project.studio ?? StudioState())
        }
        var flats: [FlatPart] = []
        measure("CNC flattening",target:3) { flats = project.parts.filter { $0.hardware != true }.map(Flatten.flat) }
        if !flats.isEmpty {
            measure("Sheet nesting",target:10) {
                let result = Nesting.nest(flats,sheetL:project.sheetLength,sheetW:project.sheetWidth,gap:project.nestGap,registration:project.studio?.registration,stocks:project.studio?.nestingStocks ?? [])
                if !result.oversize.isEmpty { throw ModelValidation.Failure(message:"\(result.oversize.count) parts or grain runs do not fit stock") }
                if result.placed.count != flats.count { throw ModelValidation.Failure(message:"Nested \(result.placed.count) of \(flats.count) parts") }
            }
        }
        return Report(partCount:count,processorCount:ProcessInfo.processInfo.activeProcessorCount,measures:measures)
    }
}
