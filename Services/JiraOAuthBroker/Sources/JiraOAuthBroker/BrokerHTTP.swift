import Foundation

struct BrokerHTTPRequest: Sendable {
    let method: String
    let target: String
    let body: Data
}

/// One request per connection. Chunked bodies and pipelining are intentionally unsupported.
enum BrokerHTTP {
    static func parse(_ data: Data) throws -> BrokerHTTPRequest? {
        guard data.count <= 81_920 else { throw BrokerError.invalidRequest }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 8192 else { throw BrokerError.invalidRequest }
            return nil
        }
        guard boundary.lowerBound <= 8192 else { throw BrokerError.invalidRequest }
        let headerBytes = data[..<boundary.lowerBound]
        guard headerBytes.allSatisfy({ $0 == 13 || $0 == 10 || (32...126).contains($0) }),
              let text = String(data: headerBytes, encoding: .utf8) else { throw BrokerError.invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, ["GET", "POST"].contains(first[0]), first[2] == "HTTP/1.1",
              first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { throw BrokerError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw BrokerError.invalidRequest }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[name] == nil else { throw BrokerError.invalidRequest }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let host = headers["host"], !host.isEmpty, headers["transfer-encoding"] == nil,
              headers["expect"] == nil else { throw BrokerError.invalidRequest }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengthText), (0...(first[1] == "/v1/refresh" ? 73_728 : 8192)).contains(length), first[0] != "GET" || length == 0 else { throw BrokerError.invalidRequest }
        if first[0] == "POST" {
            guard headers["content-length"] != nil,
                  headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else { throw BrokerError.invalidRequest }
        }
        let received = data.count - boundary.upperBound
        guard received <= length else { throw BrokerError.invalidRequest }
        guard received == length else { return nil }
        return BrokerHTTPRequest(method: String(first[0]), target: String(first[1]), body: Data(data[boundary.upperBound...]))
    }
    static func serialize(_ response: BrokerHTTPResponse) -> Data {
        response.withBody { body in
            var result = Data(("HTTP/1.1 \(response.status) Response\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n").utf8)
            result.append(body)
            return result
        }
    }
}
