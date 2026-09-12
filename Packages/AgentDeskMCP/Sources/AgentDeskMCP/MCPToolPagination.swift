import AgentDeskCore
import Foundation

public enum MCPToolPaginationError: Error, Equatable, Sendable {
    case invalidLimits, scopeMismatch, unexpectedPage, repeatedCursor, duplicateTool, limitExceeded, incomplete, closed
}
public enum MCPToolPaginationState: Equatable, Sendable {
    case pending(cursor: String?), complete, closed
}

/// A completed, scoped catalog of server claims. Raw pages still require redaction before use.
public struct MCPToolCatalog: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let pages: [MCPToolPage]
    public var tools: [MCPToolDescription] { pages.flatMap(\.tools) }
}

/// One discovery traversal. No partial result is published after malformed or mixed-scope pages.
public actor MCPToolPagination {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public private(set) var state: MCPToolPaginationState = .pending(cursor: nil)
    private let maximumPages: Int, maximumTools: Int, maximumBytes: Int
    private var pages: [MCPToolPage] = []
    private var names = Set<String>(), cursors = Set<String>()
    private var bytes = 0

    public init(scope: ProjectScope, environmentID: EnvironmentID, connectionID: UUID,
                maximumPages: Int = 100, maximumTools: Int = 10_000, maximumBytes: Int = 4_194_304) throws {
        guard (1...100).contains(maximumPages), (1...10_000).contains(maximumTools), (1...16_777_216).contains(maximumBytes) else {
            throw MCPToolPaginationError.invalidLimits
        }
        self.scope = scope; self.environmentID = environmentID; self.connectionID = connectionID
        self.maximumPages = maximumPages; self.maximumTools = maximumTools; self.maximumBytes = maximumBytes
    }
    public func append(_ page: MCPToolPage, requestedCursor: String?) throws {
        do {
            try Task.checkCancellation()
            guard case .pending(let expected) = state else { throw MCPToolPaginationError.closed }
            guard page.scope == scope, page.environmentID == environmentID, page.connectionID == connectionID else {
                throw MCPToolPaginationError.scopeMismatch
            }
            guard requestedCursor == expected else { throw MCPToolPaginationError.unexpectedPage }
            guard pages.count < maximumPages, page.tools.count <= maximumTools - names.count,
                  page.response.count <= maximumBytes - bytes else { throw MCPToolPaginationError.limitExceeded }
            var newNames = names
            for tool in page.tools {
                guard newNames.insert(tool.name).inserted else { throw MCPToolPaginationError.duplicateTool }
            }
            if let next = page.nextCursor {
                guard next != requestedCursor, !cursors.contains(next) else { throw MCPToolPaginationError.repeatedCursor }
                // A continuation at the page limit can never produce a complete bounded catalog.
                guard pages.count + 1 < maximumPages else { throw MCPToolPaginationError.limitExceeded }
            }
            pages.append(page); names = newNames; bytes += page.response.count
            if let next = page.nextCursor { cursors.insert(next); state = .pending(cursor: next) }
            else { state = .complete }
        } catch { close(); throw error }
    }
    public func catalog() throws -> MCPToolCatalog {
        try Task.checkCancellation()
        guard state == .complete else { throw state == .closed ? MCPToolPaginationError.closed : MCPToolPaginationError.incomplete }
        return MCPToolCatalog(scope: scope, environmentID: environmentID, connectionID: connectionID, pages: pages)
    }
    public func close() {
        state = .closed; pages = []; names = []; cursors = []; bytes = 0
    }
}
