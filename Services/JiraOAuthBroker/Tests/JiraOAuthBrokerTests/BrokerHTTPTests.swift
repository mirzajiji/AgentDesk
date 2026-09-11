import Foundation
import XCTest
@testable import JiraOAuthBroker

final class BrokerHTTPTests: XCTestCase {
    func testRefreshBodyBoundIsLargerOnlyOnExactRefreshRoute() throws {
        let body = Data(repeating: 65, count: 65_560)
        let header = "POST /v1/refresh HTTP/1.1\r\nHost: broker.example\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        let request = try XCTUnwrap(BrokerHTTP.parse(Data(header.utf8) + body))
        XCTAssertEqual(request.body.count, body.count)
        for path in ["/v1/attempts", "/v1/refresh?override=true"] {
            XCTAssertThrowsError(try BrokerHTTP.parse(Data(header.replacingOccurrences(of: "/v1/refresh", with: path).utf8) + body))
        }
    }
    func testFragmentedBodyAndSecurityHeaders() throws {
        let header = "POST /v1/attempts HTTP/1.1\r\nHost: broker.example\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(try BrokerHTTP.parse(Data((header + "{").utf8)))
        let request = try XCTUnwrap(BrokerHTTP.parse(Data((header + "{}").utf8)))
        XCTAssertEqual(request.body, Data("{}".utf8))
        XCTAssertEqual(request.target, "/v1/attempts")
        let wire = String(decoding: BrokerHTTP.serialize(.init(status: 200, data: Data("private".utf8))), as: UTF8.self)
        for expected in ["Cache-Control: no-store", "Referrer-Policy: no-referrer", "Content-Length: 7", "Connection: close", "frame-ancestors 'none'"] { XCTAssertTrue(wire.contains(expected)) }
    }
    func testAmbiguousFramingAndPipeliningFailClosed() throws {
        for header in [
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 1",
            "GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked",
            "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: +1",
            "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1",
            "GET / HTTP/1.1\r\n Host: x",
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8193\r\nContent-Type: application/json",
            "GET / HTTP/1.0\r\nHost: x"
        ] { XCTAssertThrowsError(try BrokerHTTP.parse(Data((header + "\r\n\r\n").utf8))) }
        XCTAssertThrowsError(try BrokerHTTP.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /next HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertThrowsError(try BrokerHTTP.parse(Data(repeating: 65, count: 8193)))
    }
}
