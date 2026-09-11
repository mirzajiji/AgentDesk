import Foundation

public enum JiraTransportError: Error, Equatable, Sendable {
    case invalidRequest, invalidResponse, responseTooLarge, redirected, closed, networkUnavailable
}

struct JiraHTTPResponse: Sendable {
    let status: Int
    let body: Data
}

/// The adapter constructs requests after authentication/policy validation. No shared cookies or cache.
actor JiraHTTPTransport {
    private let session: URLSession
    private let origin: URL
    private let maximumBytes: Int
    private var closed = false

    init(origin: URL, maximumBytes: Int = 2_097_152, protocolClasses: [URLProtocol.Type] = []) throws {
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, (1...8_388_608).contains(maximumBytes) else {
            throw JiraTransportError.invalidRequest
        }
        self.origin = origin; self.maximumBytes = maximumBytes
        let configuration = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: RejectJiraRedirects(), delegateQueue: nil)
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int? = nil) async throws -> JiraHTTPResponse {
        do { return try await perform(request, maximumResponseBytes: maximumResponseBytes) }
        catch is CancellationError { throw CancellationError() }
        catch let error as JiraTransportError { throw error }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw JiraTransportError.networkUnavailable
        }
    }

    private func perform(_ request: URLRequest, maximumResponseBytes: Int?) async throws -> JiraHTTPResponse {
        try Task.checkCancellation()
        guard !closed else { throw JiraTransportError.closed }
        let responseLimit = maximumResponseBytes ?? maximumBytes
        guard (1...maximumBytes).contains(responseLimit) else { throw JiraTransportError.invalidRequest }
        let base = origin.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = base.isEmpty ? "/" : "/" + base + "/"
        guard let url = request.url, url.scheme == origin.scheme, url.host == origin.host,
              url.port == origin.port, url.user == nil, url.password == nil, url.fragment == nil,
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              url.path == origin.path || url.path.hasPrefix(prefix) else {
            throw JiraTransportError.invalidRequest
        }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw JiraTransportError.invalidResponse }
        guard !(300...399).contains(response.statusCode) else { throw JiraTransportError.redirected }
        guard response.expectedContentLength <= Int64(responseLimit) else { throw JiraTransportError.responseTooLarge }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < responseLimit else { throw JiraTransportError.responseTooLarge }
            body.append(byte)
        }
        return JiraHTTPResponse(status: response.statusCode, body: body)
    }

    func close() { closed = true; session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
}

private final class RejectJiraRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
