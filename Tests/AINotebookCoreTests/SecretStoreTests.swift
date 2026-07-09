import XCTest
@testable import AINotebookCore

final class SecretStoreTests: XCTestCase {

    func testInMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        try store.save(providerId: "p1", secret: "sk-abc")
        XCTAssertEqual(try store.load(providerId: "p1"), "sk-abc")
    }

    func testInMemoryOverwrite() throws {
        let store = InMemorySecretStore()
        try store.save(providerId: "p1", secret: "old")
        try store.save(providerId: "p1", secret: "new")
        XCTAssertEqual(try store.load(providerId: "p1"), "new")
    }

    func testInMemoryMissingIsNil() throws {
        XCTAssertNil(try InMemorySecretStore().load(providerId: "nope"))
    }

    func testInMemoryDelete() throws {
        let store = InMemorySecretStore()
        try store.save(providerId: "p1", secret: "x")
        try store.delete(providerId: "p1")
        XCTAssertNil(try store.load(providerId: "p1"))
    }

    func testInMemoryDeleteMissingDoesNotThrow() {
        XCTAssertNoThrow(try InMemorySecretStore().delete(providerId: "nope"))
    }
}
