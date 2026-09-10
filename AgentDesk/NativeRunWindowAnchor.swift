#if os(macOS)
import AppKit
import SwiftUI

/// Captures only the containing native window, never the session or its task data.
struct NativeRunWindowAnchor: NSViewRepresentable {
    let attach: (@escaping () -> Bool) -> Void
    func makeNSView(context: Context) -> AnchorView { AnchorView(attach: attach) }
    func updateNSView(_ nsView: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        let attach: (@escaping () -> Bool) -> Void
        init(attach: @escaping (@escaping () -> Bool) -> Void) {
            self.attach = attach
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            attach { [weak window] in
                guard let window, window.isVisible else { return false }
                NSApp.activate(ignoringOtherApps: true)
                window.sheetParent?.makeKeyAndOrderFront(nil)
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
    }
}
#endif
