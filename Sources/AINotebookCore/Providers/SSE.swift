import Foundation

/// Shared Server-Sent-Events parsing for the OpenAI-shape (OpenAI, LM Studio,
/// OpenRouter, vLLM, OpenWebUI) and Anthropic streaming APIs. Pure functions —
/// no networking in this file (the CI grep gate keeps direct network calls
/// confined to the dedicated client files).
public enum SSE {
    public static let done = "[DONE]"

    /// Payload of a `data: `-prefixed SSE line; nil for any other line.
    public static func dataPayload(of line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        return String(line.dropFirst("data: ".count))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Tokens in one OpenAI-shape chunk (`choices[].delta.content`).
    /// Malformed JSON → empty array; the caller just skips the line.
    public static func openAITokens(inPayload payload: String) -> [String] {
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
              let choices = chunk.choices
        else { return [] }
        return choices.compactMap { $0.delta?.content }.filter { !$0.isEmpty }
    }

    /// One parsed Anthropic stream event; nil when the payload is not JSON.
    public static func anthropicEvent(inPayload payload: String) -> AnthropicStreamEvent? {
        guard let data = payload.data(using: .utf8),
              let raw = try? JSONDecoder().decode(AnthropicRawEvent.self, from: data)
        else { return nil }
        switch raw.type {
        case "content_block_delta":
            if raw.delta?.type == "text_delta", let text = raw.delta?.text {
                return .textDelta(text)
            }
            return .other
        case "message_delta":
            if let stop = raw.delta?.stopReason { return .stopReason(stop) }
            return .other
        case "message_stop":
            return .messageStop
        default:
            return .other
        }
    }
}

public enum AnthropicStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case stopReason(String)
    case messageStop
    case other
}

struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    let choices: [Choice]?
}

struct AnthropicRawEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let stopReason: String?
        enum CodingKeys: String, CodingKey {
            case type, text
            case stopReason = "stop_reason"
        }
    }
    let type: String
    let delta: Delta?
}
