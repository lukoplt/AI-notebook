import XCTest
@testable import AINotebookCore

final class StorePathTests: XCTestCase {
    func testInMemoryMarker() {
        let path = StorePath.inMemory
        XCTAssertTrue(path.isInMemory)
        XCTAssertNil(path.fileURL)
    }

    func testProductionURLLandsInAppSupportSubdirectory() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let path = try StorePath.production()
        XCTAssertFalse(path.isInMemory)

        let url = try XCTUnwrap(path.fileURL)
        XCTAssertEqual(url.lastPathComponent, "db.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "AINotebook")
        XCTAssertTrue(url.path.hasPrefix(appSupport.path))
    }

    func testProductionCreatesContainerDirectory() throws {
        let path = try StorePath.production()
        let dir = try XCTUnwrap(path.fileURL?.deletingLastPathComponent())
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
