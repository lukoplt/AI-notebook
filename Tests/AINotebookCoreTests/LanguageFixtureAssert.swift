import Foundation
import XCTest

/// Structural JSON comparison shared by normalization, scoring and document tests.
func assertLanguageJSON<T: Encodable>(_ actual: T, equals expected: Any,
                                     _ name: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(actual))
    let a = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    let b = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys, .fragmentsAllowed])
    XCTAssertEqual(a, b, name, file: file, line: line)
}
