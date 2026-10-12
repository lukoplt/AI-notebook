import Foundation

extension FolderEmbeddingSession {
    /// Pure availability check in contract order; `loadKey` runs only after every cheaper check passed.
    public static func availability(config: ProviderConfig?, model: String,
                                    loadKey: () throws -> String?) -> (EmbeddingAvailability, String?) {
        guard let config else { return (.noProvider, nil) }
        guard config.type.supportsEmbeddings else { return (.providerHasNoEmbeddings, nil) }
        guard config.enabled else { return (.providerDisabled, nil) }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (.noModel, nil) }
        guard !config.type.isCloud || config.privacyAcknowledged else { return (.consentRequired, nil) }
        do { return (.ready, try loadKey()) } catch { return (.credentialUnavailable, nil) }
    }

    /// Captures a raw-format session from the selected provider, or explains why none exists.
    /// Any other capture error (e.g. a malformed endpoint) maps to `noProvider`.
    public static func resolve(config: ProviderConfig?, model: String, loadKey: () throws -> String?,
                               modelDigest: String? = nil, queryFormatVersion: String = RawEmbeddingFormat.current,
                               docFormatVersion: String = RawEmbeddingFormat.current, session: URLSession = .shared) -> EmbeddingSessionResolution {
        let (availability, key) = Self.availability(config: config, model: model, loadKey: loadKey)
        guard availability == .ready, let config else { return .unavailable(availability) }
        guard let captured = try? FolderEmbeddingSession(config: config, model: model, apiKey: key, modelDigest: modelDigest,
                                                         queryFormatVersion: queryFormatVersion,
                                                         docFormatVersion: docFormatVersion, session: session) else {
            return .unavailable(.noProvider)
        }
        return .ready(captured)
    }
}
