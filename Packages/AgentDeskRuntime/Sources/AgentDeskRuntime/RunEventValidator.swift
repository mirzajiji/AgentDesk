import AgentDeskCore
import Foundation

/// Bounded untrusted event state. Valid completion also requires clean stream termination.
struct RunEventValidator {
    private let request: ExecutionRequest
    private var sequence: Int64 = 0
    private var started = false
    private var completed = false
    private var activities: [String: (ExecutionProviderEvent.Activity, Bool, WorkItemID)] = [:]
    private var messageIDs: Set<String> = []
    private var messageFingerprints: Set<ActionFingerprint> = []
    private var bytes = 0
    private(set) var finalText: String?
    init(request: ExecutionRequest) { self.request = request }
    enum Accepted {
        case started
        case activity(WorkItemID, title: String, completed: Bool)
        case message(String)
        case completed
    }
    mutating func accept(_ event: ExecutionProviderEvent) throws -> Accepted {
        guard event.identity == request.identity, event.sequence == sequence + 1, !completed,
              sequence < 4_000 else { throw RunCoordinatorError.invalidEvents }
        sequence = event.sequence
        switch event.payload {
        case .started:
            guard !started, sequence == 1 else { throw RunCoordinatorError.invalidEvents }
            started = true; return .started
        case .activity(let id, let kind, let done):
            guard started, valid(id), kind != .fileChange else { throw RunCoordinatorError.invalidEvents }
            if done {
                guard let prior = activities[id], prior.0 == kind, !prior.1 else { throw RunCoordinatorError.invalidEvents }
                activities[id] = (kind, true, prior.2)
                return .activity(prior.2, title: "", completed: true)
            }
            guard activities[id] == nil else { throw RunCoordinatorError.invalidEvents }
            guard activities.count < request.maximumActivities else { throw RunCoordinatorError.limitExceeded }
            let item = WorkItemID(); activities[id] = (kind, false, item)
            return .activity(item, title: "\(kind == .command ? "Command" : "Planning") \(activities.count)", completed: false)
        case .message(let id, let text):
            guard started, valid(id), !text.utf8.contains(0), messageIDs.insert(id).inserted else { throw RunCoordinatorError.invalidEvents }
            guard text.utf8.count <= request.maximumOutputBytes - bytes else { throw RunCoordinatorError.limitExceeded }
            bytes += text.utf8.count
            messageFingerprints.insert(try ActionFingerprint(bytes: Data(text.utf8)))
            return .message(text)
        case .completed(let text):
            guard started, text.utf8.count <= request.maximumOutputBytes, !text.isEmpty,
                  activities.values.allSatisfy({ $0.1 }),
                  messageFingerprints.contains(try ActionFingerprint(bytes: Data(text.utf8))) else { throw RunCoordinatorError.invalidEvents }
            do { try request.outputSchema?.validateOutput(text, maximumBytes: request.maximumOutputBytes) }
            catch { throw RunCoordinatorError.invalidEvents }
            completed = true; finalText = text; return .completed
        }
    }
    func finish() throws -> String {
        guard completed, let finalText else { throw RunCoordinatorError.invalidEvents }
        return finalText
    }
    private func valid(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 256 && !id.utf8.contains(0) }
}
