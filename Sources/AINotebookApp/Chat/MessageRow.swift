import AINotebookCore
import AppKit
import SwiftUI

/// Optional actions of one message row; nil hides the action.
struct MessageRowActions {
    var onCite: ((Int) -> Void)?
    var onSaveAsNote: (() -> Void)?
    var onSentContext: (() -> Void)?
    var onEdit: (() -> Void)?
    var onRegenerate: (() -> Void)?
    /// "Regenerate with …" providers (C3).
    var regenerateProviders: [ProviderConfig] = []
    var onRegenerateWith: ((ProviderConfig) -> Void)?
}

/// One conversation message (spec §2.2): the user's message as a right-aligned
/// `surface-2` block, the assistant's answer as full-width Markdown without a
/// bubble, actions revealed on hover.
struct MessageRow: View {
    let message: ChatMessage
    var isStreaming = false
    var compact = false
    var actions = MessageRowActions()

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    private var t: AppText { settings.text }

    var body: some View {
        Group {
            if message.role == .user { userMessage } else { assistantMessage }
        }
        .onHover { hovering = $0 }
    }

    // MARK: User

    private var userMessage: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.spacing(4)) {
            Spacer(minLength: 0)
            // Actions sit beside the block (no extra row height).
            HoverActions(isVisible: hovering) {
                IconButton(icon: .copy, label: t.string(.messageCopy)) { copy(message.content) }
                if let onEdit = actions.onEdit {
                    IconButton(icon: .edit, label: t.string(.chatEdit), action: onEdit)
                }
            }
            TrailingFractionLayout(fraction: compact ? 1 : DesignTokens.size(.userMessageMaxPercent) / 100) {
                Text(message.content)
                    .tokenFont(.body)
                    .tokenForeground(.text1)
                    .textSelection(.enabled)
                    .padding(.vertical, DesignTokens.size(.userMessagePadV))
                    .padding(.horizontal, DesignTokens.size(.userMessagePadH))
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.radius(.lg), style: .continuous)
                            .fill(DesignTokens.color(.surface2))
                    )
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Assistant

    private var blocks: [MarkdownBlock] { MarkdownLite.parse(message.content) }

    private var assistantMessage: some View {
        let parsed = blocks
        let inlineMarkers = MarkdownInlineRenderer.citeMarkers(in: parsed)
        let extra = message.citations.filter { !inlineMarkers.contains($0.marker) }
        return VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            MarkdownView(blocks: parsed, style: compact ? .body : .message,
                         onCite: { actions.onCite?($0) })
            if !extra.isEmpty, let onCite = actions.onCite {
                HStack(spacing: DesignTokens.spacing(4)) {
                    Text(t.string(.chatCitationsInline))
                        .tokenFont(.caption)
                        .tokenForeground(.text3)
                    ForEach(extra, id: \.marker) { c in
                        ChipButton("\(c.marker)", icon: nil) { onCite(c.marker) }
                            .help(c.displayName ?? c.relPath ?? c.snippet)
                    }
                }
            }
            if !isStreaming {
                HoverActions(isVisible: hovering) { assistantActions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var assistantActions: some View {
        IconButton(icon: .copy, label: t.string(.messageCopy)) { copy(message.content) }
        if let onRegenerate = actions.onRegenerate {
            if actions.regenerateProviders.isEmpty || actions.onRegenerateWith == nil {
                IconButton(icon: .regenerate, label: t.string(.chatRegenerate), action: onRegenerate)
            } else {
                IconMenu(icon: .regenerate, label: t.string(.chatRegenerate)) {
                    Button(t.string(.chatRegenerate), action: onRegenerate)
                    Divider()
                    Section(t.string(.composerRegenerateWith)) {
                        ForEach(actions.regenerateProviders) { provider in
                            Button(provider.name) { actions.onRegenerateWith?(provider) }
                        }
                    }
                }
            }
        }
        if let onSaveAsNote = actions.onSaveAsNote {
            IconButton(icon: .saveAsNote, label: t.string(.chatSaveAsNoteButton), action: onSaveAsNote)
        }
        if let onSentContext = actions.onSentContext {
            IconButton(icon: .sentContext, label: t.string(.contextPreviewSent), action: onSentContext)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// Places its single child at the trailing edge, at most `fraction` of the
/// offered width wide (user messages: 80 % of the column).
struct TrailingFractionLayout: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            return child.sizeThatFits(.unspecified)
        }
        let size = child.sizeThatFits(ProposedViewSize(width: width * fraction, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: nil))
        child.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}

/// Muted error line with a warning icon and "Try again" (spec §2.2).
struct ChatErrorRow: View {
    let message: String
    let retryTitle: String
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spacing(8)) {
            Image(systemName: DesignTokens.icon(.warning))
                .tokenForeground(.warning)
                .accessibilityHidden(true)
            Text(message)
                .tokenFont(.body)
                .tokenForeground(.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onRetry {
                Button(retryTitle, action: onRetry).buttonStyle(.secondary)
            }
        }
        .padding(DesignTokens.spacing(12))
        .card(radius: .md, fill: .surface1)
    }
}
