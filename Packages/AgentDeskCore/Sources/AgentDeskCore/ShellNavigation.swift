/// Presentation roles only. Navigation visibility never grants execution authority.
public enum ApplicationRole: Equatable, Sendable {
    case macHost
    case iPhoneCompanion

    public var destinations: [ShellDestination] {
        switch self {
        case .macHost: [.workspaces, .runs, .connections]
        case .iPhoneCompanion: [.companion]
        }
    }

    public var initialDestination: ShellDestination {
        switch self {
        case .macHost: .workspaces
        case .iPhoneCompanion: .companion
        }
    }
}

public enum ShellDestination: String, CaseIterable, Identifiable, Sendable {
    case workspaces
    case runs
    case connections
    case companion

    public var id: Self { self }
}

/// Keeps selection valid when restoring a route from a different platform.
public struct ShellNavigation: Equatable, Sendable {
    public let role: ApplicationRole
    public private(set) var selection: ShellDestination

    public init(role: ApplicationRole, restoring destination: ShellDestination? = nil) {
        self.role = role
        self.selection = destination.flatMap { role.destinations.contains($0) ? $0 : nil }
            ?? role.initialDestination
    }

    @discardableResult
    public mutating func select(_ destination: ShellDestination) -> Bool {
        guard role.destinations.contains(destination) else { return false }
        selection = destination
        return true
    }
}
