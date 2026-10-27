import AppKit

struct CutRow: Identifiable {
    var id: String { "\(species.rawValue)|\(t)|\(w)|\(l)|\(machiningKey)" }
    var machiningKey = ""
    var machining = ""
    var partIDs: [UUID] = []
    var labels: [String] = []
    var qty: Int
    var names: [String]
    var species: Species
    var t: Double, w: Double, l: Double
    var boardFeet: Double { t * w * l / 144 * Double(qty) }
    var sqFeet: Double { w * l / 144 * Double(qty) }
}

enum CutList {
    /// Group boards by material intent and machining, without discarding metric precision.
    static func rows(_ parts: [Part]) -> [CutRow] {
        var map: [String: CutRow] = [:]
        var order: [String] = []
        func q(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
        for p in parts where p.hardware != true {
            let axes = p.materialAxes
            var lo = SIMD3<Double>.zero, hi = p.size
            for cut in p.cuts where cut.additive && cut.suppressed != true { lo = pointwiseMin(lo, cut.lo); hi = pointwiseMax(hi, cut.hi) }
            let blankSize = hi - lo
            let d = [blankSize[axes.t], blankSize[axes.w], blankSize[axes.l]].map(q)
            let cuts = p.cuts.filter { $0.suppressed != true }.map { c in
                "\(c.kind)|\(c.lo)|\(c.hi)|\(String(describing: c.faceAxis))|\(String(describing: c.facePositive))|\(String(describing: c.runAxis))|\(String(describing: c.relief))|\(String(describing: c.allowance))"
            }.sorted().joined(separator: ";")
            let trims = p.trims.map { t in
                "\(t.axis)|\(t.positive)|\(t.run)|\(t.angle)|\(t.farEdge)"
            }.sorted().joined(separator: ";")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let profile = p.profile.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let operations = p.machiningOperations.filter { $0.suppressed != true }.map { op -> String in var n = op; n.suppressed = nil; n.patternID = nil; n.name = ""; n.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!; return (try? encoder.encode(n)).map { String(decoding: $0, as: UTF8.self) } ?? "" }.joined(separator: ";")
            let meshKey = p.mesh.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let sequenceKey = p.featureSteps.map { step -> String in
                switch step.kind {
                case .cut: return p.cuts.first { $0.id == step.feature }.map { "C|\($0.kind)|\($0.lo)|\($0.hi)|\($0.suppressed == true)" } ?? ""
                case .operation: return (p.operations ?? []).first { $0.id == step.feature }.map { "O|\($0.kind)|\($0.depth)|\($0.contour)" } ?? ""
                case .pattern: return (p.patterns ?? []).first { $0.id == step.feature }.map { "P|\($0.axis)|\($0.positive)|\($0.columns)|\($0.rows)|\($0.suppressed)" } ?? ""
                case .trim: return p.trims.first { $0.id == step.feature }.map { "T|\($0.axis)|\($0.angle)|\($0.farEdge)|\($0.suppressed == true)" } ?? ""
                }
            }.joined(separator:";")
            let key = cuts.isEmpty && trims.isEmpty && profile.isEmpty && operations.isEmpty && meshKey.isEmpty ? "" : "\(axes)|\(cuts)|\(trims)|\(profile)|\(operations)|\(meshKey)|\(sequenceKey)"
            let summary = [p.cuts.filter { $0.suppressed != true }.isEmpty ? nil : "\(p.cuts.filter { $0.suppressed != true }.count) joint(s)", p.trims.isEmpty ? nil : "\(p.trims.count) angled cut(s)",
                           p.profile == nil ? nil : "Curved outline", operations.isEmpty ? nil : "\(p.machiningOperations.count) machining operation(s)"].compactMap { $0 }.joined(separator: ", ")
            var row = CutRow(machiningKey: key, machining: summary, partIDs: [p.id], labels:[ShopIdentity.label(p)], qty: 1, names: [p.name], species: p.species, t: d[0], w: d[1], l: d[2])
            if var e = map[row.id] {
                e.qty += 1; e.names.append(p.name); e.partIDs.append(p.id); e.labels.append(ShopIdentity.label(p)); map[row.id] = e
            } else {
                row.qty = 1
                map[row.id] = row
                order.append(row.id)
            }
        }
        return order.compactMap { map[$0] }.sorted { ($0.species.rawValue, $0.l) < ($1.species.rawValue, $1.l) }
    }

    static func csv(_ rows: [CutRow], metric: Bool) -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = "Qty,Species,Thickness,Width,Length,Board Feet,Parts,Machining,Part IDs\r\n"
        for r in rows {
            let fields = ["\(r.qty)", r.species.rawValue, Units.format(r.t, metric: metric),
                          Units.format(r.w, metric: metric), Units.format(r.l, metric: metric),
                          String(format: "%.2f", r.boardFeet), r.names.joined(separator: "; "), r.machining,r.labels.joined(separator:"; ")]
            out += fields.map(quote).joined(separator: ",") + "\r\n"
        }
        return out
    }
}
