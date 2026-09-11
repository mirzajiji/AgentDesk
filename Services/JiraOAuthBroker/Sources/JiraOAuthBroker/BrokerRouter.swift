import AgentDeskSecurity
import Foundation

/// Bodies may contain credentials. Diagnostics intentionally never include them.
public struct BrokerHTTPResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let status: Int
    public let contentType: String
    private let data: Data
    public var description: String { "<broker HTTP response \(status)>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["response": description]) }
    init(status: Int, contentType: String = "application/json", data: Data) { self.status = status; self.contentType = contentType; self.data = data }
    public func withBody<T>(_ operation: (Data) throws -> T) rethrows -> T { try operation(data) }
}

public struct BrokerRouter: Sendable {
    private let attempts: BrokerAttempts
    private let callbackPath: String
    private let exchange: @Sendable (SecretValue) async throws -> SecretValue
    private let refresh: (@Sendable (SecretValue) async throws -> SecretValue)?
    public init(attempts: BrokerAttempts, callbackPath: String, exchange: AtlassianTokenExchange) throws {
        try self.init(attempts: attempts, callbackPath: callbackPath, refresh: { try await exchange.refresh(token: $0) }, exchange: { try await exchange.exchange(code: $0) })
    }
    init(attempts: BrokerAttempts, callbackPath: String, refresh: (@Sendable (SecretValue) async throws -> SecretValue)? = nil, exchange: @escaping @Sendable (SecretValue) async throws -> SecretValue) throws {
        guard callbackPath.hasPrefix("/"), !callbackPath.contains("?"), !callbackPath.contains("#"),
              callbackPath != "/v1/attempts", callbackPath.utf8.count <= 1024 else { throw BrokerError.invalidRequest }
        self.attempts = attempts; self.callbackPath = callbackPath; self.exchange = exchange; self.refresh = refresh
    }
    public func handle(method: String, target: String, body: Data) async throws -> BrokerHTTPResponse {
        try Task.checkCancellation()
        do {
            guard target.utf8.count <= 16_384, target.hasPrefix("/"), !target.hasPrefix("//"),
                  let parts = URLComponents(string: target), parts.scheme == nil, parts.host == nil, parts.fragment == nil,
                  body.count <= (parts.path == "/v1/refresh" ? 73_728 : 8192) else { throw BrokerError.invalidRequest }
            if method == "GET", parts.path == callbackPath {
                guard body.isEmpty, let query = parts.queryItems, (2...4).contains(query.count),
                      Set(query.map(\.name)).count == query.count,
                      let state = query.first(where: { $0.name == "state" })?.value,
                      state.utf8.count == 43 else { throw BrokerError.invalidRequest }
                if query.first(where: { $0.name == "error" })?.value == "access_denied" {
                    guard Set(query.map(\.name)).isSubset(of: ["state", "error", "error_description", "error_uri"]) else { throw BrokerError.invalidRequest }
                    try await attempts.deny(state: state)
                    return .init(status: 200, contentType: "text/plain; charset=utf-8", data: Data("Sign-in declined. Return to AgentDesk.".utf8))
                }
                guard query.count == 2, let code = query.first(where: { $0.name == "code" })?.value,
                      !code.isEmpty, code.utf8.count <= 8192 else { throw BrokerError.invalidRequest }
                try await attempts.complete(state: state, code: SecretValue(Data(code.utf8)), exchange: exchange)
                return .init(status: 200, contentType: "text/plain; charset=utf-8", data: Data("Sign-in received. Return to AgentDesk to finish connecting.".utf8))
            }
            guard parts.query == nil else { throw BrokerError.invalidRequest }
            if method == "POST", parts.path == "/v1/refresh" {
                guard let refresh else { return failure(status: 503, code: "unavailable") }
                let value = try object(body, key: "refresh_token")
                guard !value.isEmpty, value.utf8.count <= 32_768, value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw BrokerError.invalidRequest }
                let tokens: SecretValue
                do { tokens = try await refresh(SecretValue(Data(value.utf8))) }
                catch is CancellationError { throw CancellationError() }
                catch { throw BrokerError.exchangeFailed }
                try Task.checkCancellation()
                return tokens.withBytes { .init(status: 200, data: $0) }
            }
            if method == "POST", parts.path == "/v1/attempts" {
                let payload = try object(body, key: "challenge")
                let attempt = try await attempts.start(challenge: payload)
                let data = try JSONSerialization.data(withJSONObject: ["id": attempt.id.uuidString, "authorizationURL": attempt.authorizationURL.absoluteString])
                return .init(status: 201, data: data)
            }
            let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.count == 5, path[0].isEmpty, path[1] == "v1", path[2] == "attempts",
                  let id = UUID(uuidString: String(path[3])), path[4] == "claim" || path[4] == "cancel", method == "POST" else {
                return failure(status: 404, code: "notFound")
            }
            let verifier = try SecretValue(Data(object(body, key: "verifier").utf8))
            if path[4] == "cancel" {
                try await attempts.cancel(id: id, verifier: verifier)
                return .init(status: 204, data: Data())
            }
            let tokens = try await attempts.claim(id: id, verifier: verifier)
            return tokens.withBytes { .init(status: 200, data: $0) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as BrokerError {
            switch error {
            case .denied: return failure(status: 403, code: "denied")
            case .pending: return failure(status: 202, code: "pending")
            case .capacity: return failure(status: 429, code: "capacity")
            case .expired: return failure(status: 410, code: "expired")
            case .invalidProof: return failure(status: 403, code: "invalidProof")
            case .replay: return failure(status: 409, code: "replay")
            case .exchangeFailed: return failure(status: 502, code: "exchangeFailed")
            case .invalidRequest: return failure(status: 400, code: "invalidRequest")
            }
        } catch { return failure(status: 400, code: "invalidRequest") }
    }
    private func object(_ data: Data, key: String) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String], object.count == 1,
              let value = object[key] else { throw BrokerError.invalidRequest }
        return value
    }
    private func failure(status: Int, code: String) -> BrokerHTTPResponse {
        .init(status: status, data: Data(("{\"error\":\"" + code + "\"}").utf8))
    }
}
