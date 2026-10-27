import Foundation

enum MakeArea { case fabrication,shop }

enum MakeSection: String,CaseIterable {
    case cnc = "CNC JOB",materials = "PARTS & MATERIALS",assembly = "ASSEMBLY",project = "PROJECT"
}

enum MakeRoute: String,CaseIterable,Identifiable {
    case prepare,sheets,review,export,cutList,materials,offcuts,hardware,assemblyChecks,relationships,labels,documents
    var id: String { rawValue }
    var section: MakeSection {
        switch self {
        case .prepare,.sheets,.review,.export:return .cnc
        case .cutList,.materials,.offcuts,.hardware:return .materials
        case .assemblyChecks,.relationships,.labels:return .assembly
        case .documents:return .project
        }
    }
    var title: String {
        switch self {
        case .prepare:return "Prepare job"
        case .sheets:return "Sheet layout"
        case .review:return "Machining review"
        case .export:return "Export to VCarve"
        case .cutList:return "Cut list"
        case .materials:return "Materials & cost"
        case .offcuts:return "Offcuts"
        case .hardware:return "Hardware"
        case .assemblyChecks:return "Assembly checks"
        case .relationships:return "Part relationships"
        case .labels:return "Labels & assembly"
        case .documents:return "Documents & recovery"
        }
    }
    var symbol: String {
        switch self {
        case .prepare:return "checklist"
        case .sheets:return "square.grid.3x3"
        case .review,.assemblyChecks:return "checkmark.shield"
        case .export:return "arrow.up.forward.app"
        case .cutList:return "list.bullet.rectangle"
        case .materials:return "square.stack.3d.up"
        case .offcuts:return "square.grid.2x2"
        case .hardware:return "screwdriver"
        case .relationships:return "point.3.connected.trianglepath.dotted"
        case .labels:return "tag"
        case .documents:return "doc.text"
        }
    }
    var fabricationPage: FabricationPage? {
        switch self {
        case .prepare:return .job
        case .sheets:return .layout
        case .review:return .review
        case .export:return .handoff
        case .cutList:return .cutList
        case .labels:return .assembly
        default:return nil
        }
    }
    var shopPage: ShopPage? {
        switch self {
        case .assemblyChecks:return .checks
        case .relationships:return .relationships
        case .hardware:return .hardware
        case .materials:return .materials
        case .offcuts:return .sheets
        case .documents:return .delivery
        default:return nil
        }
    }
    static func current(_ doc: Document) -> MakeRoute {
        if doc.makeArea == .shop {
            switch ShopPage(rawValue:doc.shopTab) ?? .checks {
            case .checks:return .assemblyChecks
            case .relationships:return .relationships
            case .hardware:return .hardware
            case .materials:return .materials
            case .sheets:return .offcuts
            case .delivery:return .documents
            }
        }
        switch FabricationPage(rawValue:doc.fabricationTab) ?? .job {
        case .job:return .prepare
        case .layout:return .sheets
        case .review:return .review
        case .handoff:return .export
        case .cutList:return .cutList
        case .assembly:return .labels
        }
    }
    func select(_ doc: Document) {
        if let fabricationPage { doc.fabricationTab = fabricationPage.rawValue;doc.makeArea = .fabrication }
        else if let shopPage { doc.shopTab = shopPage.rawValue;doc.makeArea = .shop }
    }
}

extension Document {
    func openMake(_ route: MakeRoute) { route.select(self);showCutList = true }
    var fabricationSelectionProject: Project { showCutList && makeArea == .fabrication ? cncProject : project }
}
