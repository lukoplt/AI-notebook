import AppKit
import SwiftUI

/// Composer card (radius `lg`, hairline, soft shadow only while focused):
/// a 1–8 line text area where Return sends and Shift+Return inserts a newline,
/// plus a bottom row with leading controls (+, chips) and trailing ones (preview, send).
struct ComposerView<Leading: View, Trailing: View>: View {
    @Binding var text: String
    let placeholder: String
    var isSending = false
    var autoFocus = false
    let onSubmit: () -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var focused = false
    @State private var height: CGFloat = DesignTokens.lineHeight(.body)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .tokenFont(.body)
                        .tokenForeground(.text3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ComposerTextView(text: $text, height: $height, focused: $focused,
                                 isEditable: !isSending, autoFocus: autoFocus,
                                 accessibilityLabel: placeholder, onSubmit: onSubmit)
                    .frame(height: height)
            }
            HStack(spacing: DesignTokens.spacing(8)) {
                leading()
                Spacer(minLength: DesignTokens.spacing(8))
                trailing()
            }
        }
        .padding(.horizontal, DesignTokens.spacing(12))
        .padding(.top, DesignTokens.spacing(12))
        .padding(.bottom, DesignTokens.spacing(8))
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius(.lg), style: .continuous)
                .fill(DesignTokens.color(.surface1))
                .shadow(color: DesignTokens.color(.text1).opacity(focused ? 0.10 : 0),
                        radius: focused ? DesignTokens.spacing(12) : 0, y: DesignTokens.spacing(4) / 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radius(.lg), style: .continuous)
                .strokeBorder(DesignTokens.color(.border), lineWidth: DesignTokens.size(.borderWidth))
        )
    }
}

/// Round monochrome send button (primary hit target). While sending it turns
/// into Stop (`stop.fill`, ⌘.) when `onStop` is given, else shows a spinner.
struct SendButton: View {
    let isSending: Bool
    let isEnabled: Bool
    let label: String
    var stopLabel: String = ""
    var onStop: (() -> Void)?
    let action: () -> Void

    private var showsStop: Bool { isSending && onStop != nil }

    var body: some View {
        if showsStop, let onStop {
            Button(action: onStop) {
                circle {
                    Image(systemName: DesignTokens.icon(.stop))
                        .font(.system(size: DesignTokens.size(.iconRow) * 0.7, weight: .semibold))
                        .tokenForeground(.onAccent)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: [.command])
            .help(stopLabel)
            .accessibilityLabel(stopLabel)
        } else {
            Button(action: action) {
                circle {
                    if isSending {
                        ProgressView().controlSize(.mini).tint(DesignTokens.color(.onAccent))
                    } else {
                        Image(systemName: DesignTokens.icon(.send))
                            .font(.system(size: DesignTokens.size(.iconRow) * 0.85, weight: .semibold))
                            .tokenForeground(.onAccent)
                    }
                }
                .opacity(isEnabled || isSending ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled || isSending)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(label)
            .accessibilityLabel(label)
        }
    }

    private func circle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: DesignTokens.size(.primaryHitMin) - DesignTokens.spacing(4),
                   height: DesignTokens.size(.primaryHitMin) - DesignTokens.spacing(4))
            .background(Circle().fill(DesignTokens.color(.accent)))
            .contentShape(Circle())
    }
}

/// NSTextView-backed growing text area. SwiftUI's TextField cannot tell
/// Return from Shift+Return on macOS, so the field editor command is handled here.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    var isEditable: Bool
    var autoFocus: Bool
    var accessibilityLabel: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = FocusTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = DesignTokens.nsFont(.body)
        textView.textColor = DesignTokens.nsColor(.text1)
        textView.insertionPointColor = DesignTokens.nsColor(.text1)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setAccessibilityLabel(accessibilityLabel)
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = DesignTokens.lineHeight(.body)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: DesignTokens.nsFont(.body),
            .foregroundColor: DesignTokens.nsColor(.text1),
            .paragraphStyle: paragraph,
        ]
        textView.string = text
        textView.onFocusChange = { [weak coordinator = context.coordinator] isFocused in
            coordinator?.parent.focused = isFocused
        }
        scroll.documentView = textView
        context.coordinator.textView = textView
        if autoFocus {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        DispatchQueue.main.async { context.coordinator.recalculateHeight() }
        return scroll
    }

    /// Takes whatever width it is offered (never widens the column) and the
    /// computed 1–8 line height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? DesignTokens.size(.panelMin), height: height)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            DispatchQueue.main.async { context.coordinator.recalculateHeight() }
        }
        textView.isEditable = isEditable
        textView.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        /// Height for 1…8 lines (token values); taller content scrolls.
        func recalculateHeight() {
            guard let textView, let container = textView.textContainer,
                  let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let line = DesignTokens.lineHeight(.body)
            let minHeight = line * DesignTokens.size(.composerMinLines)
            let maxHeight = line * DesignTokens.size(.composerMaxLines)
            let target = min(max(used, minHeight), maxHeight)
            if abs(parent.height - target) > 0.5 { parent.height = target }
        }
    }
}

/// Reports first-responder changes (drives the composer focus shadow).
final class FocusTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}

private struct ComposerPreview: View {
    @State var text = ""
    var body: some View {
        ComposerView(text: $text, placeholder: "Ask anything in this notebook…", onSubmit: {}) {
            IconButton(icon: .add, label: "Add") {}
            ChipButton("Whole notebook", icon: .scope) {}
        } trailing: {
            IconButton(icon: .previewContext, label: "Preview context") {}
            SendButton(isSending: false, isEnabled: !text.isEmpty, label: "Send") {}
        }
        .frame(width: 600)
        .padding()
        .background(DesignTokens.color(.bg))
    }
}

#Preview("Composer light") { ComposerPreview().preferredColorScheme(.light) }
#Preview("Composer dark") { ComposerPreview().preferredColorScheme(.dark) }
