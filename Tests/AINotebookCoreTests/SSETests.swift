import XCTest
@testable import AINotebookCore

final class SSETests: XCTestCase {

    // ── data-line framing ────────────────────────────────────────────────

    func testDataPayloadExtractsPayload() {
        XCTAssertEqual(SSE.dataPayload(of: #"data: {"x":1}"#), #"{"x":1}"#)
    }

    func testNonDataLinesAreNil() {
        XCTAssertNil(SSE.dataPayload(of: "event: ping"))
        XCTAssertNil(SSE.dataPayload(of: ""))
        XCTAssertNil(SSE.dataPayload(of: ": comment"))
    }

    func testDoneSentinel() {
        XCTAssertEqual(SSE.dataPayload(of: "data: [DONE]"), SSE.done)
    }

    // ── OpenAI shape ─────────────────────────────────────────────────────

    func testOpenAITokensFromDelta() {
        let payload = #"{"choices":[{"delta":{"content":"Hello"},"index":0}]}"#
        XCTAssertEqual(SSE.openAITokens(inPayload: payload), ["Hello"])
    }

    func testOpenAITokensMultipleChoices() {
        let payload = #"{"choices":[{"delta":{"content":"A"},"index":0},{"delta":{"content":"B"},"index":1}]}"#
        XCTAssertEqual(SSE.openAITokens(inPayload: payload), ["A", "B"])
    }

    func testOpenAITokensSkipsEmptyAndMissingContent() {
        XCTAssertEqual(SSE.openAITokens(inPayload: #"{"choices":[{"delta":{"content":""},"index":0}]}"#), [])
        XCTAssertEqual(SSE.openAITokens(inPayload: #"{"choices":[{"delta":{},"index":0}]}"#), [])
        XCTAssertEqual(SSE.openAITokens(inPayload: #"{"choices":[]}"#), [])
    }

    func testOpenAITokensMalformedJSONIsEmpty() {
        XCTAssertEqual(SSE.openAITokens(inPayload: "not-json"), [])
    }

    // ── Anthropic shape ──────────────────────────────────────────────────

    func testAnthropicTextDelta() {
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
        XCTAssertEqual(SSE.anthropicEvent(inPayload: payload), .textDelta("Hi"))
    }

    func testAnthropicStopReason() {
        let payload = #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":1}}"#
        XCTAssertEqual(SSE.anthropicEvent(inPayload: payload), .stopReason("refusal"))
    }

    func testAnthropicMessageStop() {
        XCTAssertEqual(SSE.anthropicEvent(inPayload: #"{"type":"message_stop"}"#), .messageStop)
    }

    func testAnthropicPingAndUnknownAreOther() {
        XCTAssertEqual(SSE.anthropicEvent(inPayload: #"{"type":"ping"}"#), .other)
        XCTAssertEqual(SSE.anthropicEvent(inPayload: #"{"type":"content_block_start","content_block":{}}"#), .other)
    }

    func testAnthropicMalformedIsNil() {
        XCTAssertNil(SSE.anthropicEvent(inPayload: "not-json"))
    }
}
