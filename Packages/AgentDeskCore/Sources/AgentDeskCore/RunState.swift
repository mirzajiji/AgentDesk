import Foundation

public enum RunState: String, Codable, CaseIterable, Sendable {
    case queued, running, waitingForApproval, paused, completed, failed, cancelled

    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }

    /// A lifecycle transition is necessary but never sufficient authorization for an operation.
    public func canTransition(to next: RunState) -> Bool {
        switch self {
        case .queued: [.running, .waitingForApproval, .failed, .cancelled].contains(next)
        case .running: [.waitingForApproval, .paused, .completed, .failed, .cancelled].contains(next)
        case .waitingForApproval, .paused: [.running, .failed, .cancelled].contains(next)
        case .completed, .failed, .cancelled: false
        }
    }
}
