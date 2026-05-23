import XCTest
@testable import AINotebookCore

final class OllamaModelTests: XCTestCase {
    func testDecodesTagListPayload() throws {
        let json = """
        {
          "models": [
            {
              "name": "llama3.2:3b",
              "modified_at": "2024-09-25T12:00:00Z",
              "size": 2019377664,
              "digest": "abc123",
              "details": {
                "format": "gguf",
                "family": "llama",
                "parameter_size": "3B",
                "quantization_level": "Q4_K_M"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let list = try JSONDecoder().decode(OllamaModelList.self, from: json)
        XCTAssertEqual(list.models.count, 1)
        let model = list.models[0]
        XCTAssertEqual(model.name, "llama3.2:3b")
        XCTAssertEqual(model.size, 2_019_377_664)
        XCTAssertEqual(model.digest, "abc123")
        XCTAssertEqual(model.details.parameterSize, "3B")
    }

    func testEmptyListDecodes() throws {
        let json = """
        { "models": [] }
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode(OllamaModelList.self, from: json)
        XCTAssertTrue(list.models.isEmpty)
    }
}
