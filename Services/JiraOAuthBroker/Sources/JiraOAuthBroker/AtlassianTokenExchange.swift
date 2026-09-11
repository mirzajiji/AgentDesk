import AgentDeskSecurity
import Foundation

/// Confidential server-side client. Never instantiate this with a bundled native-app secret.
public actor AtlassianTokenExchange {
    private let clientID: String
    private let clientSecret: SecretValue
    private let callback: URL
    private let session: URLSession
    private var closed = false

    public init(clientID: String, clientSecret: SecretValue, callback: URL) throws {
        try self.init(clientID: clientID, clientSecret: clientSecret, callback: callback, protocolClasses: [])
    }
    init(clientID: String, clientSecret: SecretValue, callback: URL, protocolClasses: [URLProtocol.Type]) throws {
        guard !clientID.isEmpty, clientID.utf8.count <= 256, callback.scheme == "https", callback.host != nil,
              callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil else { throw BrokerError.invalidRequest }
        self.clientID = clientID; self.clientSecret = clientSecret; self.callback = callback
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: NoTokenRedirects(), delegateQueue: nil)
    }
    public func exchange(code: SecretValue) async throws -> SecretValue {
        try await send(grant: "authorization_code", value: code)
    }
    public func refresh(token: SecretValue) async throws -> SecretValue {
        // No automatic retries: an ambiguous rotating-token exchange requires reauthentication.
        try await send(grant: "refresh_token", value: token)
    }
    public func close() { closed = true; session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }

    private func send(grant: String, value: SecretValue) async throws -> SecretValue {
        try Task.checkCancellation()
        guard !closed else { throw BrokerError.exchangeFailed }
        func string(_ secret: SecretValue) throws -> String {
            try secret.withBytes { data in
                guard data.count <= 32_768, let text = String(data: data, encoding: .utf8),
                      data.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw BrokerError.invalidRequest }
                return text
            }
        }
        var body = ["grant_type": grant, "client_id": clientID, "client_secret": try string(clientSecret)]
        body[grant == "authorization_code" ? "code" : "refresh_token"] = try string(value)
        if grant == "authorization_code" { body["redirect_uri"] = callback.absoluteString }
        var request = URLRequest(url: URL(string: "https://auth.atlassian.com/oauth/token")!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= 65_536 else { throw BrokerError.exchangeFailed }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 65_536 else { throw BrokerError.exchangeFailed }
                data.append(byte)
            }
            return try Self.normalized(data, requireRefresh: grant == "refresh_token")
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BrokerError.exchangeFailed
        }
    }
    private static func normalized(_ data: Data, requireRefresh: Bool) throws -> SecretValue {
        struct Tokens: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
            let scope: String
            let token_type: String?
        }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 32_768 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 } }
        guard valid(tokens.access_token), tokens.refresh_token.map(valid) ?? !requireRefresh,
              tokens.expires_in.isFinite, tokens.expires_in > 0, tokens.expires_in <= 604_800,
              !tokens.scope.isEmpty, tokens.scope.utf8.count <= 8192,
              tokens.scope.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }),
              tokens.token_type == nil || tokens.token_type?.lowercased() == "bearer" else { throw BrokerError.exchangeFailed }
        return try SecretValue(JSONEncoder().encode(tokens))
    }
}
private final class NoTokenRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
