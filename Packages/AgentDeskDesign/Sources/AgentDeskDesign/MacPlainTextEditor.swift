#if os(macOS)
import AppKit
import SwiftUI

/// Native text entry for structured documents. Never apply prose substitutions to JSON or code.
public struct MacPlainTextEditor: NSViewRepresentable {
    @Binding private var text: String
    private let label: String
    private let identifier: String
    @ScaledMetric private var fontSize = NSFont.systemFontSize

    public init(text: Binding<String>, label: String, identifier: String) {
        _text = text; self.label = label; self.identifier = identifier
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        Self.configure(editor)
        editor.isEditable = context.environment.isEnabled
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityIdentifier(identifier)
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = context.environment.isEnabled
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let start = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        }
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static func configure(_ editor: NSTextView) {
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 6, height: 6)
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor public final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        public func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
#endif
