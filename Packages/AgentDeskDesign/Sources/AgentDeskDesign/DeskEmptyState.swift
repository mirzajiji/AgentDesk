import SwiftUI

/// A native, text-scaling empty state shared by Mac and iPhone.
public struct DeskEmptyState: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let message: LocalizedStringKey
    private let identifier: String

    public init(
        _ title: LocalizedStringKey,
        systemImage: String,
        message: LocalizedStringKey,
        accessibilityIdentifier: String
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.identifier = accessibilityIdentifier
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .accessibilityIdentifier(identifier)
    }
}
