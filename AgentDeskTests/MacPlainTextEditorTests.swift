#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AgentDeskDesign

@MainActor
final class MacPlainTextEditorTests: XCTestCase {
    func testSwiftUIDisabledStateReachesNativeTextEditor() throws {
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        for disabled in [true, false] {
            let host = NSHostingView(rootView: MacPlainTextEditor(text: .constant("Synthetic task"), label: "Task", identifier: "task")
                .disabled(disabled))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
            host.layoutSubtreeIfNeeded()
            let native = try XCTUnwrap(editor(in: host))
            XCTAssertEqual(native.isEditable, !disabled)
            XCTAssertEqual(native.string, "Synthetic task")
        }
    }
    func testNativeStructuredTextPreservesQuotesDashesAndUpdatesBinding() throws {
        let editor = NSTextView()
        MacPlainTextEditor.configure(editor)
        // These native substitutions caused valid typed JSON to become invalid at Apply.
        XCTAssertFalse(editor.isRichText)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
        let json = #"{"model":"synthetic--model","quoted":"\"literal\"","enabled":false}"#
        editor.insertText(json, replacementRange: NSRange(location: 0, length: 0))
        var bound = ""
        let coordinator = MacPlainTextEditor.Coordinator(text: Binding(get: { bound }, set: { bound = $0 }))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(bound, json)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bound.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["model"] as? String, "synthetic--model")
        XCTAssertEqual(decoded["quoted"] as? String, "\"literal\"")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: NSObject()))
        XCTAssertEqual(bound, json, "Unrelated notifications must not replace the document")
    }
}
#endif
