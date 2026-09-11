import Foundation

/// Publisher-owned public registration values. No confidential client secret belongs in the app.
public struct JiraOAuthRegistration: Sendable, Equatable {
    public let brokerOrigin: URL
    public let clientID: String
    public let callback: URL
    public init(brokerOrigin: URL, clientID: String, callback: URL) throws {
        guard brokerOrigin.scheme == "https", brokerOrigin.host != nil,
              brokerOrigin.user == nil, brokerOrigin.password == nil, brokerOrigin.query == nil, brokerOrigin.fragment == nil,
              brokerOrigin.path.isEmpty || brokerOrigin.path == "/",
              !clientID.isEmpty, clientID.utf8.count <= 256, clientID.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              callback.scheme == "https", callback.host == brokerOrigin.host,
              (callback.port ?? 443) == (brokerOrigin.port ?? 443),
              callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil,
              !callback.path.isEmpty, callback.path != "/", !callback.path.hasPrefix("/v1/"),
              callback.absoluteString.utf8.count <= 2048 else { throw JiraOAuthError.invalidConfiguration }
        self.brokerOrigin = brokerOrigin; self.clientID = clientID; self.callback = callback
    }
}
