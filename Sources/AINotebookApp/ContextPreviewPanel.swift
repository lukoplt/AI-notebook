import SwiftUI
import AINotebookCore

/// Read-only view of one immutable prepared request (WP8 §8.8). Everything is
/// derived from the snapshot itself — never from current DB or provider state —
/// so a sent preview shows exactly what was streamed. Model-facing text stays
/// in English regardless of the UI language; only labels are localized.
struct ContextPreviewPanel: View {
    let snapshot: ContextPreviewSnapshot
    let text: AppText
    @Environment(\.openSettings) private var openSettings

    private var request: PreparedContextRequest { snapshot.request }

    /// Section estimates plus the 4-token framing per logical message.
    private var estimatedTokens: Int {
        request.messages.reduce(0) { $0 + 4 + $1.sections.reduce(0) { $0 + $1.tokens } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
                header
                DisclosureGroup(text.string(.contextPreviewMessages)) { logicalMessages }
                DisclosureGroup(text.string(.contextPreviewWireOrder)) { wireOrder }
                DisclosureGroup(text.string(.contextPreviewOptions)) { options }
                DisclosureGroup(text.string(.contextPreviewCoverage)) { coverage }
                DisclosureGroup("\(text.string(.contextPreviewIncluded)) (\(request.included.count))") { included }
                DisclosureGroup("\(text.string(.contextPreviewOmitted)) (\(request.omitted.count))") { omitted }
            }
            .padding(DesignTokens.spacing(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokenFont(.caption)
            .tokenForeground(.text1)
        }
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(4)) {
            // Immutable identity captured with the request.
            Text("\(request.model.providerId) · \(request.model.model) · \(snapshot.providerType)")
                .font(Self.mono).tokenForeground(.text2)
            Text("\(text.string(.contextPreviewEstimatedTokens)): \(estimatedTokens) / \(request.model.runtimeContext - request.model.maxOutputTokens) · v\(request.estimatorVersion)")
                .tokenForeground(.text3)
                .monospacedDigit()
            if !request.model.contextWindowKnown {
                Text("\(text.string(.contextPreviewAssumedLimit)): \(request.model.runtimeContext)")
                    .tokenForeground(.warning)
                // provider-listing-limits-v1 §5: the warning leads to Settings › Models & limits.
                Button(text.string(.contextPreviewSetContextSize)) {
                    UserDefaults.standard.set(SettingsSection.modelsLimits.rawValue, forKey: SettingsSection.storageKey)
                    openSettings()
                }
                .buttonStyle(.link)
            }
        }
        .padding(.bottom, DesignTokens.spacing(4))
    }

    private var logicalMessages: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(request.messages.enumerated()), id: \.offset) { index, message in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(index + 1). \(message.role)").fontWeight(.semibold)
                    ForEach(Array(message.sections.enumerated()), id: \.offset) { _, section in
                        DisclosureGroup {
                            monospaced(section.text)
                        } label: {
                            HStack(spacing: DesignTokens.spacing(4)) {
                                Text(section.kind)
                                Text("\(section.tokens)").tokenForeground(.text3).monospacedDigit()
                            }
                        }
                    }
                }
                .padding(.leading, 6)
            }
        }
    }

    /// The provider-specific projection (Anthropic keeps a top-level system).
    private var wire: NSDictionary? {
        try? ContextPackRendering.wireObject(request, providerType: snapshot.providerType)
    }

    private var wireOrder: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let system = wire?["system"] as? String {
                Text("system (top-level)").fontWeight(.semibold)
                monospaced(system)
            }
            ForEach(Array(((wire?["messages"] as? [[String: String]]) ?? []).enumerated()), id: \.offset) { index, turn in
                DisclosureGroup("\(index + 1). \(turn["role"] ?? "")") {
                    monospaced(turn["content"] ?? "")
                }
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(wireOptions, id: \.0) { name, value in
                Text("\(name): \(value)").font(Self.mono)
            }
        }
    }

    private var wireOptions: [(String, String)] {
        var values: [(String, String)] = []
        if let nested = wire?["options"] as? [String: Int] {
            values += nested.sorted { $0.key < $1.key }.map { ($0.key, String($0.value)) }
        }
        if let max = wire?["max_tokens"] as? Int { values.append(("max_tokens", String(max))) }
        return values
    }

    private var coverage: some View {
        let corpus = request.coverage.corpus, turn = request.coverage.turn
        let lines: [(String, String)] = [
            ("corpus.filesInScope", (corpus.partial ? "≥ " : "") + String(corpus.filesInScope)),
            ("corpus.searchable", String(corpus.searchable)), ("corpus.pending", String(corpus.pending)),
            ("corpus.error", String(corpus.error)), ("corpus.skipped", String(corpus.skipped)),
            ("corpus.missing", String(corpus.missing)), ("corpus.unavailable", String(corpus.unavailable)),
            ("corpus.refreshPending", String(corpus.refreshPending)), ("corpus.refreshError", String(corpus.refreshError)),
            ("turn.passages", String(turn.passages)), ("turn.filesIncluded", String(turn.filesIncluded)),
            ("turn.candidatesWithPublishedChunks", String(turn.candidatesWithPublishedChunks)),
            ("turn.overview", String(turn.overview)),
            ("generationId", request.generationId.map(String.init) ?? "–"),
        ]
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.0) { name, value in
                Text("\(name): \(value)").font(Self.mono)
            }
        }
    }

    private var included: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(request.included.enumerated()), id: \.offset) { _, item in
                Text("\(item.kind) · \(item.id)").font(Self.mono)
            }
        }
    }

    private var omitted: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(request.omitted.enumerated()), id: \.offset) { _, item in
                Text("\(item.kind) · \(item.id) — \(text.omissionReason(item.reason))").font(Self.mono)
            }
        }
    }

    /// Caption-size monospaced text for request internals.
    private static var mono: Font { DesignTokens.font(.caption).monospaced() }

    private func monospaced(_ value: String) -> some View {
        Text(value)
            .font(Self.mono)
            .tokenForeground(.text1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.spacing(8))
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius(.sm), style: .continuous)
                    .fill(DesignTokens.color(.surface2))
            )
    }
}
