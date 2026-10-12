import Foundation
import CoreFoundation

// WP3 owns the stored value's declaration in FolderStorageTypes.swift.
// Provider policy and serialization extend that same value here.
extension ProviderModelLimits: Codable {
    private enum CodingKeys: String, CodingKey {
        case providerId, model, contextWindow, runtimeContext, maxOutputTokens, source
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(providerId: try values.decode(String.self, forKey: .providerId),
                  model: try values.decode(String.self, forKey: .model),
                  contextWindow: try values.decodeIfPresent(Int.self, forKey: .contextWindow),
                  runtimeContext: try values.decode(Int.self, forKey: .runtimeContext),
                  maxOutputTokens: try values.decode(Int.self, forKey: .maxOutputTokens),
                  source: try values.decode(String.self, forKey: .source))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(providerId, forKey: .providerId)
        try values.encode(model, forKey: .model)
        try values.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try values.encode(runtimeContext, forKey: .runtimeContext)
        try values.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try values.encode(source, forKey: .source)
    }

    public var isAssumed: Bool { source == "auto" && contextWindow == nil }

    public var options: ChatRequestOptions {
        ChatRequestOptions(runtimeContext: runtimeContext, maxOutputTokens: maxOutputTokens)
    }

    public func validate() throws {
        guard !providerId.isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source == "auto" || source == "user",
              runtimeContext > 0, maxOutputTokens > 0, maxOutputTokens < runtimeContext,
              contextWindow.map({ $0 > 0 && runtimeContext <= $0 }) ?? true else {
            throw ProviderConfigurationError.invalidLimits
        }
    }
}

public enum ProviderLimitPolicy {
    /// Automatic metadata belongs to the exact endpoint prefix and provider type.
    /// Invalid legacy roots remain editable; compare their original bytes instead.
    static func hasSameEndpoint(_ lhs: ProviderConfig, _ rhs: ProviderConfig) -> Bool {
        let leftRoot = (try? ProviderAPIRoot.normalize(lhs.baseURL)) ?? lhs.baseURL
        let rightRoot = (try? ProviderAPIRoot.normalize(rhs.baseURL)) ?? rhs.baseURL
        return lhs.type == rhs.type && leftRoot.utf8.elementsEqual(rightRoot.utf8)
    }

    /// provider-listing-limits-v1: a window the provider's own model listing advertises for an
    /// OpenWebUI / OpenAI-compatible model raises the runtime context up to this cap.
    public static let listedRuntimeCap = 32_768
    public static let listingTypes: Set<ProviderType> = [.openwebui, .openaiCompatible]

    /// `listed`: `contextWindow` comes from the provider's model listing (provider-listing-limits-v1).
    /// Every other window (Ollama show, the known OpenAI table) never raises the 8 192 default.
    public static func automatic(
        providerId: String, type: ProviderType, model: String, contextWindow: Int?, listed: Bool = false
    ) throws -> ProviderModelLimits {
        let known: Int? = type == .openai && ["gpt-4o-mini", "gpt-4o-mini-2024-07-18"].contains(model)
            ? 128_000 : nil
        let window = contextWindow ?? known
        if let window, window < 2 { throw ProviderConfigurationError.invalidLimits }
        let runtime = listed && contextWindow != nil && listingTypes.contains(type)
            ? min(contextWindow!, listedRuntimeCap)
            : min(RagContractV1.Providers.defaultRuntimeContext, window ?? Int.max)
        let output = min(RagContractV1.Providers.defaultMaxOutputTokens, runtime - 1)
        let limits = ProviderModelLimits(providerId: providerId, model: model, contextWindow: window,
            runtimeContext: runtime, maxOutputTokens: output, source: "auto")
        try limits.validate()
        return limits
    }

    /// provider-listing-limits-v1 key paths, in priority order.
    static let listingKeyPaths: [[String]] = [
        ["context_length"], ["max_model_len"], ["max_context_length"], ["context_window"], ["max_input_tokens"],
        ["top_provider", "context_length"], ["info", "params", "num_ctx"],
        ["openai", "context_length"], ["openai", "max_model_len"], ["openai", "max_context_length"],
        ["openai", "context_window"], ["openai", "max_input_tokens"],
    ]

    private static func integerWindow(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.int64Value >= 2, number.int64Value <= Int64(Int32.max) else { return nil }
        return Int(number.int64Value)
    }

    /// The first valid integer window of one listing item; nil when none.
    public static func contextWindow(fromListingItem item: [String: Any]) -> Int? {
        for path in listingKeyPaths {
            var value: Any? = item
            for key in path { value = (value as? [String: Any])?[key] }
            if let window = integerWindow(value) { return window }
        }
        return nil
    }

    /// The window of the first `data` item whose `id` equals `model` exactly; nil when unknown.
    /// Malformed JSON throws (callers treat any failure as unknown).
    public static func contextWindow(fromModelListing data: Data, model: String) throws -> Int? {
        let json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        guard let items = (json as? [String: Any])?["data"] as? [Any] else { return nil }
        for case let item as [String: Any] in items
        where (item["id"] as? String)?.unicodeScalars.elementsEqual(model.unicodeScalars) == true {
            return contextWindow(fromListingItem: item)
        }
        return nil
    }

    /// Missing or unusable metadata is unknown; malformed JSON remains an error.
    public static func contextWindow(fromOllamaShow data: Data) throws -> Int? {
        let json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        guard let object = json as? [String: Any],
              let info = object["model_info"] as? [String: Any],
              let architecture = info["general.architecture"] as? String,
              !architecture.isEmpty,
              let number = info[architecture + ".context_length"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.int64Value >= 2, number.int64Value <= Int64(Int32.max) else {
            return nil
        }
        return Int(number.int64Value)
    }
}
