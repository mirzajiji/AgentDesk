#if os(macOS)
import SwiftUI

extension View {
    /// Native editors grow with their window and keep scrollable content usable in smaller windows.
    /// Values are logical points; display pixel density and physical diagonal do not choose layout.
    public func macEditorLayout(idealWidth: CGFloat = 800, idealHeight: CGFloat = 640) -> some View {
        frame(minWidth: 600, idealWidth: idealWidth, maxWidth: .infinity,
              minHeight: 480, idealHeight: idealHeight, maxHeight: .infinity)
    }
}
#endif
