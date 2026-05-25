import XCTest
@testable import AINotebookCore

@MainActor
final class TabSwitchCoordinatorTests: XCTestCase {

    func testRequestSetsTarget() {
        let c = TabSwitchCoordinator()
        XCTAssertNil(c.target)
        c.request(.notes)
        XCTAssertEqual(c.target, .notes)
    }

    func testClearResetsTarget() {
        let c = TabSwitchCoordinator()
        c.request(.notes)
        c.clear()
        XCTAssertNil(c.target)
    }
}
