#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Foundation

enum MCPPromptTraversalError: Error, Equatable, Sendable { case repeatedCursor, duplicatePrompt, limitExceeded }
struct MCPPromptCatalog: Sendable {
    let scope: ProjectScope
    let environmentID: EnvironmentID
    let connectionID: UUID
    let pages: [MCPPromptPage]
    var prompts: [MCPPromptDescription] { pages.flatMap(\.prompts) }
}

enum MCPResourceTraversalError: Error, Equatable, Sendable { case repeatedCursor, duplicateURI, limitExceeded }
struct MCPResourceCatalog: Sendable {
    let scope: ProjectScope
    let environmentID: EnvironmentID
    let connectionID: UUID
    let pages: [MCPResourcePage]
    var resources: [MCPResourceDescription] { pages.flatMap(\.resources) }
}

enum MCPResourceTemplateTraversalError: Error, Equatable, Sendable { case repeatedCursor, duplicateTemplate, limitExceeded }
struct MCPResourceTemplateCatalog: Sendable {
    let scope: ProjectScope
    let environmentID: EnvironmentID
    let connectionID: UUID
    let pages: [MCPResourceTemplatePage]
    var resourceTemplates: [MCPResourceTemplateDescription] { pages.flatMap(\.resourceTemplates) }
}

/// Process-lifetime protocol detection and handshake boundary. No server instructions or capabilities grant authority.
actor MCPNegotiatedStdioConnection {
    nonisolated let server: MCPServerDescription
    private let scope: ProjectScope
    private let connectionID: UUID
    private let session: MCPStdioSession
    private init(session: MCPStdioSession, server: MCPServerDescription, transport: MCPStdioTransport) {
        self.session = session; self.server = server
        self.scope = transport.scope; self.connectionID = transport.connectionID
    }
    static func open(transport: MCPStdioTransport, mode: MCPProtocolMode? = nil, timeout: Duration = .seconds(10)) async throws -> MCPNegotiatedStdioConnection {
        let session = try MCPStdioSession(transport: transport)
        do {
            let description: MCPServerDescription
            if let mode {
                description = try await handshake(session, mode: mode, timeout: timeout)
            } else {
                let probe: MCPMessage?
                do {
                    probe = try await session.request(method: "server/discover",
                        params: MCPNegotiation.parameters(for: .modern), timeout: timeout)
                } catch MCPRequestError.timedOut { probe = nil }
                if let probe, case .result = probe.kind {
                    description = try MCPNegotiation.decode(probe, mode: .modern)
                } else if let probe, case .error(let code) = probe.kind, [-32020, -32021, -32022].contains(code) {
                    // These codes identify modern semantics. Only one modern revision is implemented;
                    // a rejection cannot be resolved by silently downgrading to legacy semantics.
                    throw code == -32022 ? MCPNegotiationError.unsupportedVersion : MCPNegotiationError.invalidResponse
                } else {
                    description = try await handshake(session, mode: .legacy, timeout: timeout)
                }
            }
            try Task.checkCancellation()
            return MCPNegotiatedStdioConnection(session: session, server: description, transport: transport)
        } catch { await session.close(); throw error }
    }
    private static func handshake(_ session: MCPStdioSession, mode: MCPProtocolMode, timeout: Duration) async throws -> MCPServerDescription {
        let response = try await session.request(method: mode == .modern ? "server/discover" : "initialize",
            params: MCPNegotiation.parameters(for: mode), timeout: timeout)
        let description = try MCPNegotiation.decode(response, mode: mode)
        if mode == .legacy { try await session.notify(method: "notifications/initialized") }
        return description
    }
    func ping() async throws -> MCPMessage {
        try await session.request(method: "ping", params: server.mode == .modern ? MCPNegotiation.parameters(for: .modern) : Data("{}".utf8))
    }
    /// Internal discovery only. Callers must authorize the read and redact the completed catalog.
    func discoverTools(environmentID: EnvironmentID, timeout: Duration = .seconds(30)) async throws -> MCPToolCatalog {
        let traversal = try MCPToolPagination(scope: scope, environmentID: environmentID, connectionID: connectionID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while case .pending(let cursor) = await traversal.state {
                try Task.checkCancellation()
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw MCPRequestError.timedOut }
                let response = try await session.request(method: "tools/list",
                    params: MCPToolDiscovery.parameters(mode: server.mode, cursor: cursor), timeout: remaining)
                let page = try MCPToolDiscovery.decode(response, mode: server.mode, scope: scope,
                    environmentID: environmentID, connectionID: connectionID)
                try await traversal.append(page, requestedCursor: cursor)
            }
            return try await traversal.catalog()
        } catch { await traversal.close(); throw error }
    }
    /// Keeps partial pages local; failed or cancelled traversals never publish a catalog.
    func discoverPrompts(environmentID: EnvironmentID, timeout: Duration = .seconds(30)) async throws -> MCPPromptCatalog {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
        var cursor: String?, pages: [MCPPromptPage] = []
        var cursors = Set<String>(), names = Set<String>(), bytes = 0
        repeat {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw MCPRequestError.timedOut }
            let response = try await session.request(method: "prompts/list",
                params: MCPPromptDiscovery.parameters(mode: server.mode, cursor: cursor), timeout: remaining)
            let page = try MCPPromptDiscovery.decode(response, mode: server.mode, scope: scope,
                environmentID: environmentID, connectionID: connectionID)
            guard pages.count < 100, page.prompts.count <= 10_000 - names.count,
                  page.response.count <= 4_194_304 - bytes else { throw MCPPromptTraversalError.limitExceeded }
            for prompt in page.prompts {
                guard names.insert(prompt.name).inserted else { throw MCPPromptTraversalError.duplicatePrompt }
            }
            if let next = page.nextCursor {
                guard next != cursor, cursors.insert(next).inserted else { throw MCPPromptTraversalError.repeatedCursor }
                guard pages.count + 1 < 100 else { throw MCPPromptTraversalError.limitExceeded }
            }
            pages.append(page); bytes += page.response.count; cursor = page.nextCursor
        } while cursor != nil
        try Task.checkCancellation()
        return MCPPromptCatalog(scope: scope, environmentID: environmentID, connectionID: connectionID, pages: pages)
    }
    /// Keeps partial pages local; failed or cancelled traversals never publish a catalog.
    func discoverResources(environmentID: EnvironmentID, timeout: Duration = .seconds(30)) async throws -> MCPResourceCatalog {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
        var cursor: String?, pages: [MCPResourcePage] = []
        var cursors = Set<String>(), uris = Set<String>(), bytes = 0
        repeat {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw MCPRequestError.timedOut }
            let response = try await session.request(method: "resources/list",
                params: MCPResourceDiscovery.parameters(mode: server.mode, cursor: cursor), timeout: remaining)
            let page = try MCPResourceDiscovery.decode(response, mode: server.mode, scope: scope,
                environmentID: environmentID, connectionID: connectionID)
            guard pages.count < 100, page.resources.count <= 10_000 - uris.count,
                  page.response.count <= 4_194_304 - bytes else { throw MCPResourceTraversalError.limitExceeded }
            for resource in page.resources {
                guard uris.insert(resource.uri).inserted else { throw MCPResourceTraversalError.duplicateURI }
            }
            if let next = page.nextCursor {
                guard next != cursor, cursors.insert(next).inserted else { throw MCPResourceTraversalError.repeatedCursor }
                guard pages.count + 1 < 100 else { throw MCPResourceTraversalError.limitExceeded }
            }
            pages.append(page); bytes += page.response.count; cursor = page.nextCursor
        } while cursor != nil
        try Task.checkCancellation()
        return MCPResourceCatalog(scope: scope, environmentID: environmentID, connectionID: connectionID, pages: pages)
    }
    /// Internal template traversal; templates remain unexpanded and unredacted.
    func discoverResourceTemplates(environmentID: EnvironmentID, timeout: Duration = .seconds(30)) async throws -> MCPResourceTemplateCatalog {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
        var cursor: String?, pages: [MCPResourceTemplatePage] = []
        var cursors = Set<String>(), uris = Set<String>(), bytes = 0
        repeat {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw MCPRequestError.timedOut }
            let response = try await session.request(method: "resources/templates/list",
                params: MCPResourceTemplateDiscovery.parameters(mode: server.mode, cursor: cursor), timeout: remaining)
            let page = try MCPResourceTemplateDiscovery.decode(response, mode: server.mode, scope: scope,
                environmentID: environmentID, connectionID: connectionID)
            guard pages.count < 100, page.resourceTemplates.count <= 10_000 - uris.count,
                  page.response.count <= 4_194_304 - bytes else { throw MCPResourceTemplateTraversalError.limitExceeded }
            for resource in page.resourceTemplates {
                guard uris.insert(resource.uriTemplate).inserted else { throw MCPResourceTemplateTraversalError.duplicateTemplate }
            }
            if let next = page.nextCursor {
                guard next != cursor, cursors.insert(next).inserted else { throw MCPResourceTemplateTraversalError.repeatedCursor }
                guard pages.count + 1 < 100 else { throw MCPResourceTemplateTraversalError.limitExceeded }
            }
            pages.append(page); bytes += page.response.count; cursor = page.nextCursor
        } while cursor != nil
        try Task.checkCancellation()
        return MCPResourceTemplateCatalog(scope: scope, environmentID: environmentID, connectionID: connectionID, pages: pages)
    }
    /// Internal read boundary; the host must authorize the exact URI and redact returned content.
    func readResource(uri: String, environmentID: EnvironmentID, timeout: Duration = .seconds(30)) async throws -> MCPResourceReadResult {
        try Task.checkCancellation()
        let response = try await session.request(method: "resources/read",
            params: MCPResourceRead.parameters(mode: server.mode, uri: uri), timeout: timeout)
        return try MCPResourceRead.decode(response, mode: server.mode, requestedURI: uri,
            scope: scope, environmentID: environmentID, connectionID: connectionID)
    }
    func close() async { await session.close() }
}
#endif
