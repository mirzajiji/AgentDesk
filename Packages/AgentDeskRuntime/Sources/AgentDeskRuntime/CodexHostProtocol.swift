#if os(macOS)
import Foundation

@objc public protocol CodexHostXPC {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

public struct CodexHostRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case inspect, login, logout }
    public let operation: Operation
    public let executable: URL?
    public let installation: CodexInstallation?
    public init(operation: Operation, executable: URL? = nil, installation: CodexInstallation? = nil) {
        self.operation = operation; self.executable = executable; self.installation = installation
    }
    public func validate() throws {
        for path in [executable, installation?.executable].compactMap({ $0 }) {
            guard path.isFileURL, path.path.hasPrefix("/"), path.path.utf8.count <= 4_096,
                  !path.path.utf8.contains(0) else { throw CodexDiagnosticIssue.invalidExecutable }
        }
        guard operation == .inspect ? installation == nil : installation != nil && executable == nil else {
            throw CodexDiagnosticIssue.commandFailed
        }
    }
}

public enum CodexHostContract {
    public static let serviceName = "com.mirza.AgentDesk.CodexHost"
    public static let clientRequirement = #"anchor apple generic and identifier "com.mirza.AgentDesk" and certificate leaf[subject.OU] = "3R9673A8NL""#
    public static let serviceRequirement = #"anchor apple generic and identifier "com.mirza.AgentDesk.CodexHost" and certificate leaf[subject.OU] = "3R9673A8NL""#
    public static let maximumMessageBytes = 16_384

    public static func respond(to data: Data, using service: any CodexDiagnosing) async -> Data {
        let snapshot: CodexDiagnosticSnapshot
        do {
            guard data.count <= maximumMessageBytes else { throw CodexDiagnosticIssue.outputLimit }
            let request = try JSONDecoder().decode(CodexHostRequest.self, from: data)
            try request.validate()
            switch request.operation {
            case .inspect: snapshot = try await service.inspect(executable: request.executable)
            case .login:
                guard let installation = request.installation else { throw CodexDiagnosticIssue.commandFailed }
                snapshot = try await service.login(using: installation)
            case .logout:
                guard let installation = request.installation else { throw CodexDiagnosticIssue.commandFailed }
                snapshot = try await service.logout(using: installation)
            }
        } catch { snapshot = CodexDiagnosticSnapshot(installation: nil, authentication: .unknown, issue: error as? CodexDiagnosticIssue ?? .commandFailed) }
        return (try? JSONEncoder().encode(snapshot)) ?? Data()
    }
}

/// One connection-scoped operation. Invalidation cancels work and its child process group.
public actor CodexHostSession {
    private let service: any CodexDiagnosing
    private var task: Task<Data, Never>?
    private var closed = false
    public init(service: any CodexDiagnosing = MacCodexDiagnostics()) { self.service = service }
    public func perform(_ request: Data) async -> Data {
        guard !closed, task == nil else {
            return (try? JSONEncoder().encode(CodexDiagnosticSnapshot(installation: nil, authentication: .unknown, issue: .busy))) ?? Data()
        }
        let service = service
        let work = Task { await CodexHostContract.respond(to: request, using: service) }
        task = work
        let result = await work.value
        task = nil
        return result
    }
    public func invalidate() { closed = true; task?.cancel() }
    deinit { task?.cancel() }
}
#endif
