import SwiftUI
import AppKit

/// What to buy: rough-lumber board feet, which boards to cut parts from, sheet counts and hardware.
enum Buying {
    struct Hardwood: Identifiable {
        var id: String { "\(species.rawValue)-\(quarters)" }
        var species: Species
        var quarters: Int
        var parts: Int
        var finishedBF: Double
        var roughBF: Double
        var label: String { "\(quarters)/4" }
    }

    struct StockBoard: Identifiable {
        let id = UUID()
        var species: Species
        var thickness: Double
        var width: Double
        var length: Double
        var pieces: [Double]
        var kerf: Double
        var used: Double { pieces.reduce(0) { $0 + $1 } + kerf * Double(max(pieces.count - 1, 0)) }
        var waste: Double { max(length - used, 0) }
    }

    struct SheetNeed: Identifiable {
        var id: String { group }
        var group: String
        var sheets: Int
    }

    /// Rough thickness in quarter-inches for a finished thickness (allows 1/8" for planing).
    static func quarters(forFinished t: Double) -> Int {
        let need = Int(((t + 0.125) * 4 - 1e-9).rounded(.up))
        return [4, 5, 6, 8, 10, 12, 16].first { $0 >= need } ?? need
    }

    static func hardwood(_ rows: [CutRow], waste: Double) -> [Hardwood] {
        var map: [String: Hardwood] = [:]
        var order: [String] = []
        for r in rows where !r.species.isSheet {
            let q = quarters(forFinished: r.t)
            let rough = (Double(q) / 4) * (r.w + 0.25) * (r.l + 1) / 144 * Double(r.qty)
            let key = "\(r.species.rawValue)-\(q)"
            if var h = map[key] {
                h.parts += r.qty; h.finishedBF += r.boardFeet; h.roughBF += rough; map[key] = h
            } else {
                map[key] = Hardwood(species: r.species, quarters: q, parts: r.qty, finishedBF: r.boardFeet, roughBF: rough)
                order.append(key)
            }
        }
        return order.compactMap { map[$0] }.map { var h = $0; h.roughBF *= 1 + waste; return h }
    }

    /// First-fit-decreasing, per species + thickness + width. Parts longer than the stock get a board of their own length.
    static func plan(_ rows: [CutRow], stockLength: Double, kerf: Double) -> [StockBoard] {
        var groups: [String: [CutRow]] = [:]
        var order: [String] = []
        for r in rows where !r.species.isSheet {
            let key = "\(r.species.rawValue)|\(r.t)|\(r.w)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        var out: [StockBoard] = []
        for key in order {
            let g = groups[key]!
            let lengths = g.flatMap { Array(repeating: $0.l, count: $0.qty) }.sorted(by: >)
            var boards: [StockBoard] = []
            for len in lengths {
                if let i = boards.firstIndex(where: { $0.length - $0.used >= len + kerf }) {
                    boards[i].pieces.append(len)
                } else {
                    boards.append(StockBoard(species: g[0].species, thickness: g[0].t, width: g[0].w,
                                             length: max(stockLength, len), pieces: [len], kerf: kerf))
                }
            }
            out += boards
        }
        return out
    }

    static func sheets(_ parts: [Part], sheetL: Double, sheetW: Double, gap: Double) -> [SheetNeed] {
        let flat = parts.filter { $0.hardware != true && $0.species.isSheet }.map(Flatten.flat)
        let result = Nesting.nest(flat, sheetL: sheetL, sheetW: sheetW, gap: gap)
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in result.sheets {
            if counts[s.group] == nil { order.append(s.group) }
            counts[s.group, default: 0] += 1
        }
        return order.map { SheetNeed(group: $0, sheets: counts[$0]!) }
    }

    /// Hardware parts counted by name (trailing numbers from auto-naming are ignored).
    static func hardware(_ parts: [Part]) -> [(name: String, qty: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for p in parts where p.hardware == true {
            let base = p.name.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)
            if counts[base] == nil { order.append(base) }
            counts[base, default: 0] += 1
        }
        return order.map { ($0, counts[$0]!) }
    }

    static func csv(parts: [Part], stockLength: Double, kerf: Double, waste: Double, metric: Bool,
                    sheetL: Double, sheetW: Double, gap: Double) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = CutList.rows(parts)
        var out = "Section,Item,Quantity,Detail\r\n"
        for h in hardwood(rows, waste: waste) {
            out += ["Rough lumber", "\(h.species.rawValue) \(h.label)", String(format: "%.1f bf", h.roughBF),
                    "\(h.parts) parts, \(String(format: "%.1f", h.finishedBF)) bf finished, \(Int(waste * 100))% waste"].map(q).joined(separator: ",") + "\r\n"
        }
        for b in plan(rows, stockLength: stockLength, kerf: kerf) {
            out += ["Cut plan", "\(b.species.rawValue) \(Units.format(b.thickness, metric: metric)) x \(Units.format(b.width, metric: metric)) x \(Units.format(b.length, metric: metric))",
                    "1", b.pieces.map { Units.format($0, metric: metric) }.joined(separator: " + ")].map(q).joined(separator: ",") + "\r\n"
        }
        for s in sheets(parts, sheetL: sheetL, sheetW: sheetW, gap: gap) {
            out += ["Sheet goods", s.group, "\(s.sheets)", "\(Units.format(sheetL, metric: metric)) x \(Units.format(sheetW, metric: metric))"].map(q).joined(separator: ",") + "\r\n"
        }
        for h in hardware(parts) { out += ["Hardware", h.name, "\(h.qty)", ""].map(q).joined(separator: ",") + "\r\n" }
        return out
    }
}

struct BuyListView: View {
    @ObservedObject var doc: Document
    @State private var stockLength = 96.0
    @State private var kerf = 0.125
    @State private var wastePercent = 15.0

    private func save() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "\(doc.fileName) buy list.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = Buying.csv(parts: doc.parts, stockLength: stockLength, kerf: kerf, waste: wastePercent / 100,
                              metric: doc.metric, sheetL: doc.sheetLength, sheetW: doc.sheetWidth, gap: doc.nestGap)
        do { try text.write(to: url, atomically: true, encoding: .utf8); doc.status = "Saved buy list." }
        catch { doc.status = "Buy list save failed: \(error.localizedDescription)" }
    }

    var body: some View {
        let rows = CutList.rows(doc.parts)
        let hardwood = Buying.hardwood(rows, waste: wastePercent / 100)
        let boards = Buying.plan(rows, stockLength: stockLength, kerf: kerf)
        let sheets = Buying.sheets(doc.parts, sheetL: doc.sheetLength, sheetW: doc.sheetWidth, gap: doc.nestGap)
        let hardware = Buying.hardware(doc.parts)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DimField(label: "Board length", value: $stockLength, metric: doc.metric, minimum: 1)
                    DimField(label: "Saw kerf", value: $kerf, metric: doc.metric, minimum: 0)
                    AngleField(label: "Waste %", value: $wastePercent, limit: 100)
                }
                GroupBox("Rough lumber (planed allowance: +1/8\" thickness, +1/4\" width, +1\" length)") {
                    VStack(alignment: .leading, spacing: 3) {
                        if hardwood.isEmpty { Text("No solid-wood parts.").foregroundStyle(.secondary) }
                        ForEach(hardwood) { h in
                            Text("\(h.species.rawValue) \(h.label): buy about \(String(format: "%.1f", h.roughBF)) bf  (\(h.parts) parts, \(String(format: "%.1f", h.finishedBF)) bf finished)")
                                .font(.callout)
                        }
                    }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Cut plan — \(boards.count) board(s) of \(doc.fmt(stockLength))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(boards) { b in
                            Text("\(b.species.rawValue) \(doc.fmt(b.thickness)) × \(doc.fmt(b.width)) × \(doc.fmt(b.length)):  "
                                 + b.pieces.map { doc.fmt($0) }.joined(separator: " + ")
                                 + "   (waste \(doc.fmt(b.waste)))")
                                .font(.callout)
                        }
                        Text("Parts are grouped by exact thickness and width. A board can be ripped to give several of the same width.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Sheet goods (\(doc.fmt(doc.sheetLength)) × \(doc.fmt(doc.sheetWidth)))") {
                    VStack(alignment: .leading, spacing: 3) {
                        if sheets.isEmpty { Text("No sheet-good parts.").foregroundStyle(.secondary) }
                        ForEach(sheets) { Text("\($0.group): \($0.sheets) sheet(s)").font(.callout) }
                    }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Hardware") {
                    VStack(alignment: .leading, spacing: 3) {
                        if hardware.isEmpty { Text("No hardware added. Choose a hardware item in the stock picker and add it.").foregroundStyle(.secondary) }
                        ForEach(hardware, id: \.name) { Text("\($0.qty) × \($0.name)").font(.callout) }
                    }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Save Buy List CSV…") { save() }
                    Button("Copy Buy List CSV") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Buying.csv(parts: doc.parts, stockLength: stockLength, kerf: kerf, waste: wastePercent / 100,
                                                                  metric: doc.metric, sheetL: doc.sheetLength, sheetW: doc.sheetWidth, gap: doc.nestGap),
                                                       forType: .string)
                        doc.status = "Copied buy list."
                    }
                }
            }.padding(12)
        }
    }
}
