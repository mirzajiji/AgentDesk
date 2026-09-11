import AgentDeskSecurity
import Foundation

/// Public deployment values plus a separately supplied confidential secret.
public struct BrokerServiceConfiguration: Sendable {
    public let clientID: String
    public let callback: URL
    public let port: UInt16
    public let clientSecret: SecretValue

    public init(environment: [String: String], secretInput: Data) throws {
        guard let clientID = environment["AGENTDESK_JIRA_CLIENT_ID"],
              !clientID.isEmpty, clientID.utf8.count <= 256,
              clientID.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              let text = environment["AGENTDESK_JIRA_CALLBACK"], text.utf8.count <= 2048,
              let callback = URL(string: text), callback.scheme == "https", callback.host != nil,
              callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil,
              !callback.path.isEmpty, callback.path != "/", !callback.path.hasPrefix("/v1/"),
              let portText = environment["AGENTDESK_JIRA_PORT"], !portText.isEmpty,
              portText.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(portText), port > 0 else {
            throw BrokerError.invalidRequest
        }
        var bytes = secretInput
        if bytes.last == 10 { bytes.removeLast(); if bytes.last == 13 { bytes.removeLast() } }
        guard !bytes.isEmpty, bytes.count <= 32_768, bytes.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw BrokerError.invalidRequest
        }
        self.clientID = clientID; self.callback = callback; self.port = port
        self.clientSecret = try SecretValue(bytes)
    }
}
