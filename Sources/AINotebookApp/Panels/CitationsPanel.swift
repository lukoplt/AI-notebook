import AINotebookCore
import AppKit
import SwiftUI

/// Citations of the focused answer (spec §2.3): one card per citation, the
/// clicked marker highlighted and scrolled into view.
struct CitationsPanel: View {
    let model: ChatViewModel
    let notebookId: Int64

    @EnvironmentObject private var settings: AppSettings

    private var t: AppText { settings.text }

    var body: some View {
        if let focus = model.citationFocus, !focus.citations.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
                        ForEach(focus.citations, id: \.marker) { citation in
                            CitationCard(citation: citation, notebookId: notebookId,
                                         isFocused: citation.marker == focus.marker)
                                .id(citation.marker)
                        }
                    }
                    .padding(DesignTokens.spacing(12))
                }
                .onAppear { proxy.scrollTo(focus.marker, anchor: .top) }
                .onChange(of: focus.marker) { _, marker in proxy.scrollTo(marker, anchor: .top) }
            }
        } else {
            PanelHint(icon: .citation, text: t.string(.citationsPanelEmpty))
        }
    }
}

/// One citation's saved evidence snapshot; it never needs the original.
/// "Open original" asks the native resolver again on every click (current
/// source, folder root, revision and physical containment) and opens only a
/// URL returned as available/changed. Note citations keep note navigation.
struct CitationCard: View {
    let citation: Citation
    let notebookId: Int64
    var isFocused = true

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var noteJump: NoteJumpCoordinator
    @EnvironmentObject private var chatHolder: ChatEngineHolder

    @State private var state: ResolvedCitationOriginal?
    @State private var opening = false
    /// Legacy (v1) citations carry no saved title/page; looked up live.
    @State private var legacyTitle = ""
    @State private var legacyPageHint: Int?

    private var t: AppText { settings.text }

    private var title: String {
        citation.displayName ?? citation.relPath ?? legacyTitle
    }

    /// Saved spans win over the legacy chunk lookup.
    private var pageLabel: String? {
        if let span = citation.spans.first, let from = span.pageFrom {
            if let to = span.pageTo, to != from { return String(format: t.string(.citationPage), "\(from)–\(to)") }
            return String(format: t.string(.citationPage), "\(from)")
        }
        return legacyPageHint.map { String(format: t.string(.citationPage), "\($0)") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spacing(8)) {
                Text("\(citation.marker)")
                    .tokenFont(.caption)
                    .monospacedDigit()
                    .tokenForeground(.text2)
                    .padding(.horizontal, DesignTokens.spacing(4) + 2)
                    .background(Capsule().fill(DesignTokens.color(.surface2)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).tokenFont(.body).fontWeight(.medium).tokenForeground(.text1).lineLimit(2)
                    if let relPath = citation.relPath, relPath != title {
                        Text(relPath).tokenFont(.caption).tokenForeground(.text3)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if let pageLabel {
                    Text(pageLabel).tokenFont(.caption).tokenForeground(.text3)
                }
            }
            if let message = stateMessage {
                Label(message, systemImage: DesignTokens.icon(state?.decision == .changed ? .warning : .info))
                    .tokenFont(.caption)
                    .tokenForeground(state?.decision == .changed ? .warning : .text2)
            }
            Text(citation.text ?? citation.snippet)
                .tokenFont(.body)
                .tokenForeground(.text2)
                .lineLimit(isFocused ? nil : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            actionButton
        }
        .padding(DesignTokens.spacing(12))
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius(.md), style: .continuous)
                .fill(DesignTokens.color(.surface1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radius(.md), style: .continuous)
                .strokeBorder(DesignTokens.color(isFocused ? .text3 : .border),
                              lineWidth: DesignTokens.size(.borderWidth))
        )
        .task(id: citation) {
            loadLegacyDetails()
            state = await resolve()
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let noteId = state?.noteId {
            Button { noteJump.request(noteId: noteId) } label: {
                Label(t.string(.openNoteFromCitation), systemImage: DesignTokens.icon(.openOriginal))
            }
            .buttonStyle(QuietButtonStyle(token: .focus))
            .tokenFont(.caption)
        } else if state == nil || state?.decision == .available || state?.decision == .changed {
            Button { Task { await openOriginal() } } label: {
                Label(t.string(.citationOpenOriginal), systemImage: DesignTokens.icon(.openOriginal))
            }
            .buttonStyle(QuietButtonStyle(token: .focus))
            .tokenFont(.caption)
            .disabled(opening || state == nil)
        }
    }

    private var stateMessage: String? {
        guard let state, state.noteId == nil else { return nil }
        switch state.decision {
        case .available: return nil
        case .changed: return t.string(.citationRevisionChanged)
        case .unavailable: return t.string(.citationOriginalUnavailable)
        case .unsafe: return t.string(.citationOriginalOutsideFolder)
        }
    }

    private func loadLegacyDetails() {
        legacyTitle = citation.displayName == nil && citation.relPath == nil
            ? ((try? store.source(id: citation.sourceId))?.title ?? "") : ""
        legacyPageHint = citation.spans.isEmpty
            ? ((try? store.chunks(sourceId: citation.sourceId)) ?? []).first(where: { $0.id == citation.chunkId })?.pageHint
            : nil
    }

    private func resolve() async -> ResolvedCitationOriginal {
        (try? await chatHolder.originals.resolve(notebookId: notebookId, citation: citation))
            ?? ResolvedCitationOriginal(decision: .unavailable)
    }

    /// Revalidates now; never reuses a URL captured before the click.
    @MainActor
    private func openOriginal() async {
        opening = true
        defer { opening = false }
        let fresh = await resolve()
        state = fresh
        if let noteId = fresh.noteId {
            noteJump.request(noteId: noteId)
        } else if fresh.decision == .available || fresh.decision == .changed, let url = fresh.url {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Quiet centered hint for an empty panel segment.
struct PanelHint: View {
    let icon: DesignTokens.Icon
    let text: String

    var body: some View {
        VStack(spacing: DesignTokens.spacing(8)) {
            TokenIcon(icon: icon, size: .iconTopBar, color: .text3)
            Text(text)
                .tokenFont(.caption)
                .tokenForeground(.text3)
                .multilineTextAlignment(.center)
        }
        .padding(DesignTokens.spacing(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
