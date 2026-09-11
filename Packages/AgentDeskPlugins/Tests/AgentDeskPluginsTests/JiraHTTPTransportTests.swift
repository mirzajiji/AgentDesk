import Foundation
import XCTest
import Synchronization
@testable import AgentDeskPlugins

final class JiraHTTPTransportTests: XCTestCase {
    func testRejectsUnsafeOriginsAndInvalidLimits() throws {
        for value in ["http://jira.example.test", "https://user:secret@jira.example.test",
                      "https://jira.example.test?token=value", "https://jira.example.test#fragment"] {
            XCTAssertThrowsError(try JiraHTTPTransport(origin: XCTUnwrap(URL(string: value))))
        }
        let origin = try XCTUnwrap(URL(string: "https://jira.example.test"))
        XCTAssertThrowsError(try JiraHTTPTransport(origin: origin, maximumBytes: 0))
        XCTAssertThrowsError(try JiraHTTPTransport(origin: origin, maximumBytes: 8_388_609))
    }

    func testBasePathAndClosedTransportFailBeforeNetworkAccess() async throws {
        let transport = try JiraHTTPTransport(origin: XCTUnwrap(URL(string: "https://jira.example.test/company")))
        for path in ["/other/rest/api/3/myself", "/company-sibling/rest/api/3/myself", "/company/../other"] {
            do {
                _ = try await transport.send(URLRequest(url: XCTUnwrap(URL(string: "https://jira.example.test" + path))))
                XCTFail("Escaped configured base path")
            } catch { XCTAssertEqual(error as? JiraTransportError, .invalidRequest) }
        }
        await transport.close()
        do {
            _ = try await transport.send(URLRequest(url: XCTUnwrap(URL(string: "https://jira.example.test/company/rest/api/3/myself"))))
            XCTFail("Closed transport sent a request")
        } catch { XCTAssertEqual(error as? JiraTransportError, .closed) }
    }

    func testBoundedResponsesAndStatusCodes() async throws {
        let origin = try XCTUnwrap(URL(string: "https://jira.example.test"))
        let transport = try JiraHTTPTransport(origin: origin, maximumBytes: 4, protocolClasses: [SyntheticJiraProtocol.self])
        let exact = try await transport.send(URLRequest(url: origin.appendingPathComponent("exact")))
        XCTAssertEqual(exact.status, 200)
        XCTAssertEqual(exact.body, Data("1234".utf8))
        let unauthorized = try await transport.send(URLRequest(url: origin.appendingPathComponent("unauthorized")))
        XCTAssertEqual(unauthorized.status, 401)
        for endpoint in ["oversized", "advertised"] {
            do {
                _ = try await transport.send(URLRequest(url: origin.appendingPathComponent(endpoint)))
                XCTFail("Oversized response accepted")
            } catch { XCTAssertEqual(error as? JiraTransportError, .responseTooLarge) }
        }
        do {
            _ = try await transport.send(URLRequest(url: origin.appendingPathComponent("redirect")))
            XCTFail("Redirect response accepted")
        } catch { XCTAssertEqual(error as? JiraTransportError, .redirected) }
        await transport.close()
    }

    func testPerRequestLimitCannotExceedTransportAndStopsOversizedBody() async throws {
        let origin = try XCTUnwrap(URL(string: "https://jira.example.test"))
        let transport = try JiraHTTPTransport(origin: origin, maximumBytes: 100, protocolClasses: [SyntheticJiraProtocol.self])
        let request = URLRequest(url: origin.appendingPathComponent("exact"))
        for limit in [0, 101] {
            do {
                _ = try await transport.send(request, maximumResponseBytes: limit)
                XCTFail("Invalid per-request limit accepted")
            } catch { XCTAssertEqual(error as? JiraTransportError, .invalidRequest) }
        }
        do {
            _ = try await transport.send(request, maximumResponseBytes: 3)
            XCTFail("Request ceiling did not bound the response")
        } catch { XCTAssertEqual(error as? JiraTransportError, .responseTooLarge) }
        let exact = try await transport.send(request, maximumResponseBytes: 4)
        XCTAssertEqual(exact.body.count, 4)
        let normal = try await transport.send(URLRequest(url: origin.appendingPathComponent("oversized")))
        XCTAssertEqual(normal.body.count, 5, "A smaller request limit must not alter later requests")
        await transport.close()
    }

    func testNetworkFailureDoesNotExposeServerDiagnostics() async throws {
        let origin = try XCTUnwrap(URL(string: "https://jira.example.test"))
        let transport = try JiraHTTPTransport(origin: origin, protocolClasses: [SyntheticJiraProtocol.self])
        do {
            _ = try await transport.send(URLRequest(url: origin.appendingPathComponent("network-failure")))
            XCTFail("Failed request succeeded")
        } catch {
            XCTAssertEqual(error as? JiraTransportError, .networkUnavailable)
            XCTAssertFalse(String(reflecting: error).contains("synthetic-private"))
        }
        await transport.close()
    }

    func testCallerCancellationStopsStalledResponse() async throws {
        let origin = try XCTUnwrap(URL(string: "https://jira.example.test"))
        let transport = try JiraHTTPTransport(origin: origin, protocolClasses: [SyntheticJiraProtocol.self])
        let identifier = UUID().uuidString
        var request = URLRequest(url: origin.appendingPathComponent("stalled"))
        request.setValue(identifier, forHTTPHeaderField: "X-Synthetic-ID")
        let frozen = request
        let task = Task { try await transport.send(frozen) }
        let startedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !SyntheticJiraProtocol.started.withLock({ $0.contains(identifier) }), ContinuousClock.now < startedDeadline {
            await Task.yield()
        }
        XCTAssertTrue(SyntheticJiraProtocol.started.withLock { $0.contains(identifier) })
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled response succeeded") }
        catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        let stoppedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !SyntheticJiraProtocol.stopped.withLock({ $0.contains(identifier) }), ContinuousClock.now < stoppedDeadline {
            await Task.yield()
        }
        XCTAssertTrue(SyntheticJiraProtocol.stopped.withLock { $0.contains(identifier) })
        _ = SyntheticJiraProtocol.started.withLock { $0.remove(identifier) }
        _ = SyntheticJiraProtocol.stopped.withLock { $0.remove(identifier) }
        await transport.close()
    }

    func testRejectsCrossOriginRequestsBeforeNetworkAccess() async throws {
        let transport = try JiraHTTPTransport(origin: XCTUnwrap(URL(string: "https://jira.example.test")))
        for value in ["https://other.example.test/rest/api/3/myself", "http://jira.example.test/rest/api/3/myself",
                      "https://jira.example.test:8443/rest/api/3/myself", "https://user:secret@jira.example.test/rest/api/3/myself",
                      "https://jira.example.test/rest/api/3/myself#fragment"] {
            do {
                _ = try await transport.send(URLRequest(url: XCTUnwrap(URL(string: value))))
                XCTFail("Unsafe request accepted")
            } catch { XCTAssertEqual(error as? JiraTransportError, .invalidRequest) }
        }
        await transport.close()
    }
}

private final class SyntheticJiraProtocol: URLProtocol {
    static let started = Mutex<Set<String>>([])
    static let stopped = Mutex<Set<String>>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if let id = request.value(forHTTPHeaderField: "X-Synthetic-ID") { _ = Self.started.withLock { $0.insert(id) } }
        let endpoint = url.lastPathComponent
        if endpoint == "network-failure" {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: URLError.cannotConnectToHost.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-private diagnostic"]))
            return
        }
        let status = endpoint == "unauthorized" ? 401 : (endpoint == "redirect" ? 302 : 200)
        let headers = endpoint == "advertised" ? ["Content-Length": "100"] : [:]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if endpoint == "stalled" { return }
        client?.urlProtocol(self, didLoad: Data((endpoint == "oversized" ? "12345" : "1234").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if let id = request.value(forHTTPHeaderField: "X-Synthetic-ID") { _ = Self.stopped.withLock { $0.insert(id) } }
    }
}
