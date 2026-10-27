import Foundation

/// Bounded, thread-safe caches omit revision snapshots and transient selection.
/// Geometry edits, parameters, material, stock, registration, and tools invalidate them.
enum CNCAnalysis {
    private struct Key: Equatable {
        var parts: [Part];var parameters: [DesignParameter];var setup: CNCSetupProfile?
        var length: Double;var width: Double;var gap: Double;var registration: Registration;var stocks: [SheetStock];var metric: Bool
        init(_ p: Project) {
            parts = p.parts;parameters = p.studio?.parameters ?? [];setup = p.studio?.setupProfile
            length = p.sheetLength;width = p.sheetWidth;gap = p.nestGap;registration = p.studio?.registration ?? Registration();stocks = p.studio?.nestingStocks ?? [];metric = p.metric
        }
    }
    private static let lock = NSLock()
    private static var layoutEntries: [(Key,Nesting.Result)] = []
    private static var reviewEntries: [(Key,[MachiningIssue])] = []
    static func layout(_ project: Project) -> Nesting.Result {
        let key = Key(project);lock.lock();let found = layoutEntries.first { $0.0 == key }?.1;lock.unlock()
        if let found { return found }
        let result = Nesting.nest(project.parts.filter { $0.hardware != true }.map(Flatten.flat),sheetL:project.sheetLength,sheetW:project.sheetWidth,gap:project.nestGap,registration:key.registration,stocks:key.stocks)
        lock.lock();layoutEntries.insert((key,result),at:0);layoutEntries = Array(layoutEntries.prefix(2));lock.unlock();return result
    }
    static func review(_ project: Project) -> [MachiningIssue] {
        let key = Key(project);lock.lock();let found = reviewEntries.first { $0.0 == key }?.1;lock.unlock()
        if let found { return found }
        let result = MachiningReview.issues(project:project)
        lock.lock();reviewEntries.insert((key,result),at:0);reviewEntries = Array(reviewEntries.prefix(2));lock.unlock();return result
    }
    static func reset() { lock.lock();layoutEntries = [];reviewEntries = [];lock.unlock() }
}

enum CNCVectorAudit {
    /// Check serialized DXF again, rather than relying on the producer's in-memory values.
    static func validate(_ data: Data,metric: Bool) throws -> (polylines:Int,vertices:Int,layers:[String]) {
        let text = String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\r",with:"")
        let lines = text.split(separator:"\n",omittingEmptySubsequences:false).map(String.init)
        var pairs: [(Int,String)] = [];var index = 0
        while index+1<lines.count {
            guard let code = Int(lines[index].trimmingCharacters(in:.whitespaces)) else { throw ModelValidation.Failure(message:"DXF contains a malformed group code.") }
            pairs.append((code,lines[index+1].trimmingCharacters(in:.whitespaces)));index += 2
        }
        guard pairs.last?.1 == "EOF",let unit = pairs.firstIndex(where: { $0.1 == "$INSUNITS" }),unit+1<pairs.count,
              pairs[unit+1].1 == (metric ? "4" : "1") else { throw ModelValidation.Failure(message:"DXF units or file terminator do not match the job.") }
        var count = 0,vertices = 0,layers: Set<String> = [],points = 0,inside = false,closed = false
        for pair in pairs {
            if pair.0 == 0,pair.1 == "POLYLINE" { guard !inside else { throw ModelValidation.Failure(message:"DXF has a nested unfinished polyline.") };inside = true;closed = false;points = 0;count += 1 }
            if inside,pair.0 == 70,pair.1 == "1" { closed = true }
            if pair.0 == 0,pair.1 == "VERTEX" { points += 1;vertices += 1 }
            if pair.0 == 8 { layers.insert(pair.1) }
            if [10,20,30,40].contains(pair.0),Double(pair.1)?.isFinite != true { throw ModelValidation.Failure(message:"DXF contains a nonfinite coordinate or text size.") }
            if pair.0 == 0,pair.1 == "SEQEND" {
                guard inside,closed,points>=3 else { throw ModelValidation.Failure(message:"A CNC boundary is open or has too few vertices.") };inside = false
            }
        }
        guard !inside,count>0 else { throw ModelValidation.Failure(message:"DXF contains no complete closed boundaries.") }
        return (count,vertices,layers.sorted())
    }
}
