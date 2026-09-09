import Darwin
import Foundation
import XCTest
@testable import AgentDeskCore

final class ConfigurationDirectoryTests: XCTestCase {
    func testTrustedContainerTraversalDoesNotRequireListingPrivateAncestors() throws {
        let ancestor = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = ancestor.appendingPathComponent("AuthorizedContainer")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { chmod(ancestor.path, 0o700); try? FileManager.default.removeItem(at: ancestor) }
        XCTAssertEqual(chmod(ancestor.path, 0o100), 0)
        let directory = try ConfigurationDirectory(trustedContainer: container)
        try directory.write(Data("synthetic".utf8), to: "configuration.json")
        XCTAssertEqual(try directory.read("configuration.json", maximumBytes: 100), Data("synthetic".utf8))
        XCTAssertEqual(try directory.names(), ["configuration.json"])
        XCTAssertThrowsError(try directory.child("../outside"))
    }
}
