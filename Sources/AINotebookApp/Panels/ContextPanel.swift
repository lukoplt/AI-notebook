import AINotebookCore
import SwiftUI

/// Context panel (spec §2.3): the prepared request for the next message
/// (WP8 preview before send) or the context sent with an earlier answer.
struct ContextPanel: View {
    let model: ChatViewModel

    @EnvironmentObject private var settings: AppSettings

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DesignTokens.spacing(12))
                .padding(.vertical, DesignTokens.spacing(8))
            Hairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.spacing(8)) {
            Text(model.sentPreview != nil ? t.string(.contextPreviewSent) : t.string(.contextPanelDraft))
                .tokenFont(.caption)
                .fontWeight(.medium)
                .tokenForeground(.text2)
            Spacer(minLength: 0)
            if model.sentPreview != nil {
                Button(t.string(.contextPanelBackToDraft)) { model.sentPreview = nil }
                    .buttonStyle(QuietButtonStyle(token: .focus))
                    .tokenFont(.caption)
            } else {
                IconButton(icon: .regenerate, label: t.string(.contextPreviewRecalculate)) {
                    model.startPreparingDraft()
                }
                .disabled(!model.canPreview)
            }
        }
        .frame(minHeight: DesignTokens.size(.hitMin))
    }

    @ViewBuilder
    private var content: some View {
        if let item = model.sentPreview {
            if let snapshot = item.snapshot {
                ContextPreviewPanel(snapshot: snapshot, text: t)
            } else {
                // Evicted or lost on restart; never rebuilt from current DB state.
                PanelHint(icon: .sentContext, text: t.string(.contextPreviewUnavailable))
            }
        } else if model.preparing {
            HStack(spacing: DesignTokens.spacing(8)) {
                ProgressView().controlSize(.small)
                Text(t.string(.contextPreviewPreparing)).tokenFont(.caption).tokenForeground(.text2)
            }
            .padding(DesignTokens.spacing(12))
        } else if let error = model.previewError {
            Label(error, systemImage: DesignTokens.icon(.warning))
                .tokenFont(.caption)
                .tokenForeground(.text2)
                .padding(DesignTokens.spacing(12))
        } else if let snapshot = model.previewSnapshot {
            ContextPreviewPanel(snapshot: snapshot, text: t)
        } else {
            PanelHint(icon: .previewContext, text: t.string(.contextPanelHint))
        }
    }
}
