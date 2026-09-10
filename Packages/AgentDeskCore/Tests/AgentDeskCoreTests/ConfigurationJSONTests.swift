import Foundation
import XCTest
@testable import AgentDeskCore

final class ConfigurationJSONTests: XCTestCase {
    private struct Value: Codable, Equatable { let revision: Int; let path: String }
    func testPreservesNativeConfigurationValues() throws {
        let expected = Value(revision: 2, path: "/synthetic/Project 🧪")
        XCTAssertEqual(try ConfigurationJSON.decode(Value.self, from: JSONEncoder().encode(expected)), expected)
    }
    func testDuplicateKeysAndEscapedAliasesFailBeforeDecoding() {
        for text in [#"{"revision":1,"revision":2,"path":"/synthetic"}"#, #"{"revision":1,"revis\u0069on":2,"path":"/synthetic"}"#] {
            XCTAssertThrowsError(try ConfigurationJSON.decode(Value.self, from: Data(text.utf8)))
        }
    }
    func testMalformedDeepAndOversizedDocumentsFail() {
        let inputs = [Data([0xff]), Data("{bad".utf8), Data(repeating: 32, count: 262_145),
            Data((String(repeating: "[", count: 42) + "0" + String(repeating: "]", count: 42)).utf8)]
        for input in inputs { XCTAssertThrowsError(try ConfigurationJSON.decode(Value.self, from: input)) }
    }
}
