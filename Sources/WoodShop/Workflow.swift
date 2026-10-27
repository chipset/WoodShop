import SwiftUI
import AppKit

// MARK: - Recent files

enum Recents {
    private static let key = "recentFiles"
    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func add(_ url: URL) {
        // Scratch files (tests, temporary exports) don't belong in the menu.
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard !url.resolvingSymlinksInPath().path.hasPrefix(temp) else { return }
        var paths = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - Copy, cut, paste

extension Document {
    private static var clipboard: [Part] = []
    private static var pasteCount = 0

    func copyBoards() {
        let chosen = parts.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else { status = "Select boards to copy."; return }
        Document.clipboard = chosen
        Document.pasteCount = 0
        status = "Copied \(chosen.count) board(s)."
    }

    func cutBoards() {
        guard !workspaceInspectionOnly else { return }
        copyBoards()
        if parts.contains(where: { selectedIDs.contains($0.id) }) { deleteSelected() }
    }

    func pasteBoards() {
        guard !workspaceInspectionOnly else { return }
        guard !Document.clipboard.isEmpty else { status = "Nothing to paste."; return }
        Document.pasteCount += 1
        let shift = SIMD3(2.0, 0, 2.0) * Double(Document.pasteCount)
        let source = Document.clipboard
        transaction {
            var ids: Set<UUID> = []
            for var p in source {
                p.id = UUID(); p.shopNumber = nil; p.component = nil; p.origin += shift
                p.bindings?.removeAll { [.position, .rotation].contains($0.target) }
                // Linked joinery belongs to its mating board, which may not be in this paste.
                let dropped = Set(p.cuts.filter { $0.mateID != nil }.map(\.id))
                p.cuts.removeAll { dropped.contains($0.id) }
                p.featureOrder = p.featureOrder?.filter { !($0.kind == .cut && dropped.contains($0.feature)) }
                parts.append(p); ids.insert(p.id)
            }
            selection = ids.first; selectedIDs = ids; selectedFace = nil
        }
        recordHistory("Paste parts")
        status = "Pasted \(source.count) board(s)."
    }

    func selectAllBoards() {
        let visible = parts.filter(isVisible)
        guard !visible.isEmpty else { return }
        selection = visible.first?.id
        selectedIDs = Set(visible.map(\.id))
        selectedFace = nil
        status = "Selected \(visible.count) board(s)."
    }
}

// MARK: - Inspector sections

struct MovementSection: View {
    @ObservedObject var doc: Document
    let part: Part

    var body: some View {
        GroupBox("Wood movement") {
            VStack(alignment: .leading, spacing: 5) {
                if part.species.movementPerPercentMC > 0 {
                    let across = part.size[part.materialAxes.w]
                    let swing = across * part.species.movementPerPercentMC * 4
                    Text("Seasonal movement across the \(doc.fmt(across)) width: about \(doc.fmt(swing)) for a 4% moisture swing (flat-sawn).")
                        .font(.caption)
                    if swing >= 0.0625 {
                        Text("Allow for it: floating panels, elongated screw holes or breadboard ends — don't glue this across the grain.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else if part.species.isSheet {
                    Text("Sheet goods move very little across the panel.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
    }
}
