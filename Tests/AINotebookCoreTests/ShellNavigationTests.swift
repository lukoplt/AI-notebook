import XCTest
@testable import AINotebookCore

/// Navigation rules of the redesigned macOS shell (UI redesign B3).
@MainActor
final class ShellNavigationTests: XCTestCase {

    func testLegacyTabRequestsMapToShellTargets() {
        XCTAssertEqual(ShellNavigation.target(for: .sources), .panel(.sources))
        XCTAssertEqual(ShellNavigation.target(for: .notes), .panel(.notes))
        XCTAssertEqual(ShellNavigation.target(for: .chat), .thread)
        XCTAssertEqual(ShellNavigation.target(for: .transformations), .runTool)
    }

    func testNoteChatSegmentOnlyInDocumentMode() {
        XCTAssertEqual(ShellNavigation.segments(documentMode: false), [.sources, .notes, .context, .citations])
        XCTAssertEqual(ShellNavigation.segments(documentMode: true), [.sources, .notes, .noteChat, .citations])
    }

    func testResolvedSegmentFallsBackPerMode() {
        XCTAssertEqual(ShellNavigation.resolvedSegment(.noteChat, documentMode: false), .context)
        XCTAssertEqual(ShellNavigation.resolvedSegment(.context, documentMode: true), .noteChat)
        XCTAssertEqual(ShellNavigation.resolvedSegment(.notes, documentMode: true), .notes)
        XCTAssertEqual(ShellNavigation.resolvedSegment(.citations, documentMode: false), .citations)
    }

    func testVisibleSessionsCapsAtLimitUnlessExpanded() {
        let ids = Array(1...11)
        let capped = ShellNavigation.visibleSessions(ids, showAll: false, limit: 8)
        XCTAssertEqual(capped.visible, Array(1...8))
        XCTAssertEqual(capped.hidden, 3)
        let all = ShellNavigation.visibleSessions(ids, showAll: true, limit: 8)
        XCTAssertEqual(all.visible, ids)
        XCTAssertEqual(all.hidden, 0)
        let few = ShellNavigation.visibleSessions([1, 2], showAll: false, limit: 8)
        XCTAssertEqual(few.visible, [1, 2])
        XCTAssertEqual(few.hidden, 0)
        let exact = ShellNavigation.visibleSessions(Array(1...8), showAll: false, limit: 8)
        XCTAssertEqual(exact.hidden, 0)
    }

    func testSessionTitleCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(ShellNavigation.sessionTitle(firstMessage: "  Co   říká\nzdroj?  ", fallback: "New chat"),
                       "Co říká zdroj?")
        XCTAssertEqual(ShellNavigation.sessionTitle(firstMessage: " \n ", fallback: "New chat"), "New chat")
        let long = String(repeating: "ž", count: 60)
        let title = ShellNavigation.sessionTitle(firstMessage: long, fallback: "x", maxLength: 48)
        XCTAssertEqual(title.count, 48)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(ShellNavigation.sessionTitle(firstMessage: "abcd efgh", fallback: "x", maxLength: 6), "abcd…")
        XCTAssertEqual(ShellNavigation.sessionTitle(firstMessage: "abcdef", fallback: "x", maxLength: 6), "abcdef")
    }

    func testSelectionAfterDeletingPrefersNextThenPrevious() {
        XCTAssertEqual(ShellNavigation.selectionAfterDeleting(2, from: [1, 2, 3]), 3)
        XCTAssertEqual(ShellNavigation.selectionAfterDeleting(3, from: [1, 2, 3]), 2)
        XCTAssertNil(ShellNavigation.selectionAfterDeleting(1, from: [1]))
        XCTAssertNil(ShellNavigation.selectionAfterDeleting(9, from: [1, 2]))
    }
}
