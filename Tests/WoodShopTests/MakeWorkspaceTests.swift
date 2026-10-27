import XCTest
import AppKit
@testable import WoodShop

final class MakeWorkspaceTests: XCTestCase {
    func testEveryFormerFabricationAndShopPageHasOneMakeRoute() {
        XCTAssertEqual(MakeRoute.allCases.count,FabricationPage.allCases.count+ShopPage.allCases.count)
        XCTAssertEqual(Set(MakeRoute.allCases.compactMap(\.fabricationPage)),Set(FabricationPage.allCases))
        XCTAssertEqual(Set(MakeRoute.allCases.compactMap(\.shopPage)),Set(ShopPage.allCases))
        XCTAssertTrue(MakeRoute.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }
    func testMakeNavigationPreservesProjectAndReachesEveryPage() {
        let doc = Document(startRecoveryTimer:false)
        doc.insertExample()
        let original = doc.project
        for route in MakeRoute.allCases {
            doc.showCutList = false
            doc.openMake(route)
            XCTAssertTrue(doc.showCutList,route.title)
            XCTAssertEqual(MakeRoute.current(doc),route)
            if let fab = route.fabricationPage { XCTAssertEqual(doc.fabricationTab,fab.rawValue);XCTAssertEqual(doc.makeArea,.fabrication) }
            if let shop = route.shopPage { XCTAssertEqual(doc.shopTab,shop.rawValue);XCTAssertEqual(doc.makeArea,.shop) }
            XCTAssertEqual(doc.project,original,"Navigation changed the project on \(route.title)")
        }
    }
    func testExistingCommandsStillReachDesignMachiningAndMake() {
        let doc = Document(startRecoveryTimer:false)
        doc.insertExample()
        doc.select(doc.parts[0].id)
        let ctrl = SceneController(doc:doc)
        WorkspaceAction.parameters.run(doc:doc,ctrl:ctrl)
        XCTAssertTrue(doc.showDesign)
        WorkspaceAction.machine.run(doc:doc,ctrl:ctrl)
        XCTAssertTrue(doc.showMachiningRecipes)
        WorkspaceAction.cnc.run(doc:doc,ctrl:ctrl)
        XCTAssertTrue(doc.showCutList)
        XCTAssertEqual(MakeRoute.current(doc),.prepare)
    }
    func testShopDocumentsKeepWholeProjectWhenCNCSelectionIsActive() {
        let doc = Document(startRecoveryTimer:false)
        doc.insertExample()
        doc.add(Part(name:"Second board",origin:.zero,size:SIMD3(8,0.75,4),species:.plywood))
        doc.cncPartIDs = [doc.parts[0].id]
        doc.openMake(.labels)
        XCTAssertEqual(doc.fabricationSelectionProject.parts.count,1)
        doc.openMake(.documents)
        XCTAssertEqual(doc.fabricationSelectionProject.parts.count,doc.parts.count)
    }
}
