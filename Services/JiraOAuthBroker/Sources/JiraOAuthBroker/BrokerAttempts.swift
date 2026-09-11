import AgentDeskSecurity
import CryptoKit
import Foundation
import Security

public enum BrokerError: Error, Equatable, Sendable {
    case invalidRequest, capacity, expired, invalidProof, pending, replay, exchangeFailed, denied
}

public struct BrokerAttempt: Sendable {
    public let id: UUID
    public let authorizationURL: URL
}

/// In-memory attempts only. HTTP routing and confidential exchange remain separate boundaries.
public actor BrokerAttempts {
    private struct Record {
        let challenge: String
        let state: String
        let expires: Date
        var exchanging = false
        var denied = false
        var tokens: SecretValue?
        var exchangeTask: Task<SecretValue, any Error>?
    }
    private var records: [UUID: Record] = [:]
    private var closed = false
    var retainedAttemptCount: Int { records.count }
    private let clientID: String
    private let callback: URL
    private let now: @Sendable () -> Date
    private var lastTime: Date?
    private let capacity: Int
    public init(clientID: String, callback: URL, capacity: Int = 1000, now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard !clientID.isEmpty, clientID.utf8.count <= 256, callback.scheme == "https", callback.host != nil,
              callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil,
              (1...1000).contains(capacity) else { throw BrokerError.invalidRequest }
        self.clientID = clientID; self.callback = callback; self.capacity = capacity; self.now = now
    }
    public func start(challenge: String) throws -> BrokerAttempt {
        let instant = try sweep()
        guard Self.validProof(challenge) else { throw BrokerError.invalidRequest }
        guard records.count < capacity else { throw BrokerError.capacity }
        var random = Data(count: 32)
        guard random.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else { throw BrokerError.invalidRequest }
        let state = Self.base64URL(random), id = UUID()
        var url = URLComponents(string: "https://auth.atlassian.com/authorize")!
        url.queryItems = [.init(name: "audience", value: "api.atlassian.com"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: callback.absoluteString), .init(name: "scope", value: "read:jira-user read:jira-work offline_access"),
            .init(name: "state", value: state), .init(name: "response_type", value: "code"), .init(name: "prompt", value: "consent")]
        records[id] = Record(challenge: challenge, state: state, expires: instant.addingTimeInterval(600))
        return BrokerAttempt(id: id, authorizationURL: url.url!)
    }
    public func complete(state: String, code: SecretValue,
                         exchange: @escaping @Sendable (SecretValue) async throws -> SecretValue) async throws {
        _ = try sweep()
        guard let id = records.first(where: { Self.equal($0.value.state, state) })?.key,
              var record = records[id] else { throw BrokerError.expired }
        guard !record.exchanging, !record.denied else { throw BrokerError.replay }
        let task = Task { try await exchange(code) }
        record.exchanging = true; record.exchangeTask = task; records[id] = record
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            _ = try sweep()
            guard var current = records[id] else { throw BrokerError.expired }
            current.tokens = result; current.exchangeTask = nil; records[id] = current
        } catch {
            records.removeValue(forKey: id)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? BrokerError { throw error }
            throw BrokerError.exchangeFailed
        }
    }
    public func deny(state: String) throws {
        _ = try sweep()
        guard let id = records.first(where: { Self.equal($0.value.state, state) })?.key,
              var record = records[id] else { throw BrokerError.expired }
        guard !record.exchanging, !record.denied else { throw BrokerError.replay }
        record.denied = true; records[id] = record
    }
    public func claim(id: UUID, verifier: SecretValue) throws -> SecretValue {
        _ = try sweep()
        let record = try authorized(id: id, verifier: verifier)
        if record.denied { records.removeValue(forKey: id); throw BrokerError.denied }
        guard let tokens = record.tokens else { throw BrokerError.pending }
        records.removeValue(forKey: id)
        return tokens
    }
    public func cancel(id: UUID, verifier: SecretValue) throws {
        _ = try sweep()
        let record = try authorized(id: id, verifier: verifier)
        records.removeValue(forKey: id)
        record.exchangeTask?.cancel()
    }
    /// Called periodically by the service, independently of incoming requests.
    public func expirePending() {
        _ = try? sweep()
    }
    public func shutdown() async {
        closed = true
        let pending = records.values.compactMap(\.exchangeTask)
        records.removeAll()
        for task in pending { task.cancel() }
        for task in pending { _ = try? await task.value }
    }
    private func authorized(id: UUID, verifier: SecretValue) throws -> Record {
        guard let record = records[id] else { throw BrokerError.expired }
        let value = verifier.withBytes { String(decoding: $0, as: UTF8.self) }
        guard Self.validProof(value), Self.equal(record.challenge, Self.base64URL(Data(SHA256.hash(data: Data(value.utf8))))) else { throw BrokerError.invalidProof }
        return record
    }
    private func sweep() throws -> Date {
        try Task.checkCancellation()
        guard !closed else { throw BrokerError.expired }
        let instant = now()
        guard instant.timeIntervalSince1970.isFinite, lastTime.map({ instant >= $0 }) ?? true else {
            for record in records.values { record.exchangeTask?.cancel() }
            records.removeAll(); throw BrokerError.expired
        }
        lastTime = instant
        for record in records.values where record.expires <= instant { record.exchangeTask?.cancel() }
        records = records.filter { $0.value.expires > instant }
        return instant
    }
    private static func validProof(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
