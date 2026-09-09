#if os(macOS)
import Foundation

/// Fixed launch configuration. Request text cannot add flags, integrations or filesystem grants.
enum CodexExecutionConfiguration {
    static let overrides: [String: CodexJSONValue] = [
        "analytics.enabled": .bool(false), "otel.exporter": .string("none"), "otel.metrics_exporter": .string("none"),
        "features.apps": .bool(false), "features.plugins": .bool(false), "features.hooks": .bool(false),
        "features.js_repl": .bool(false), "features.multi_agent": .bool(false), "features.multi_agent_v2": .bool(false), "agents.enabled": .bool(false),
        "apps._default.enabled": .bool(false), "mcp_servers": .object([:]), "plugins": .object([:]),
        "project_doc_max_bytes": .integer(0), "web_search": .string("disabled"), "allow_login_shell": .bool(false),
        "shell_environment_policy.inherit": .string("none"), "shell_environment_policy.experimental_use_profile": .bool(false),
        "features.shell_snapshot": .bool(false), "features.shell_snapshot_v2": .bool(false),
        "features.memories": .bool(false), "features.external_agent_memory_import": .bool(false),
        "features.browser_use": .bool(false), "features.browser_use_external": .bool(false), "features.computer_use": .bool(false),
        "features.remote_plugin": .bool(false), "features.skill_search": .bool(false), "features.skill_mcp_dependency_install": .bool(false),
        "features.skip_host_skill_discovery": .bool(true)
    ]
    static func arguments(directory: URL, profile: String) throws -> [String] {
        var arguments: [String] = []
        // The CLI reloads configuration at turn/start, so the profile must exist at process scope.
        for (key, value) in configuration(directory: directory, profile: profile).sorted(by: { $0.key < $1.key }) {
            arguments += ["-c", "\(key)=\(try toml(value))"]
        }
        return arguments + ["app-server", "--stdio", "--strict-config"]
    }
    private static func toml(_ value: CodexJSONValue) throws -> String {
        switch value {
        case .object(let values):
            return "{" + (try values.sorted(by: { $0.key < $1.key }).map { "\(try toml(.string($0.key)))=\(try toml($0.value))" }).joined(separator: ",") + "}"
        case .string, .bool, .integer:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        default: throw ExecutionProviderError.invalidRequest
        }
    }
    private static func configuration(directory: URL, profile: String) -> [String: CodexJSONValue] {
        var configuration = overrides
        // A generated profile name and a replacement table prevent inherited profile roots from merging in.
        configuration["permissions"] = .object([profile: .object([
            "filesystem": .object([":minimal": .string("read"), ":workspace_roots": .string("read")]),
            "network": .object(["enabled": .bool(false)])
        ])])
        configuration["default_permissions"] = .string(profile)
        configuration["projects"] = .object([directory.path: .object(["trust_level": .string("untrusted")])])
        return configuration
    }
    static func threadParameters(request: ExecutionRequest, directory: URL, profile: String) -> CodexJSONValue {
        var parameters: [String: CodexJSONValue] = [
            "cwd": .string(directory.path), "approvalPolicy": .string("never"), "permissions": .string(profile),
            "runtimeWorkspaceRoots": .array([.string(directory.path)]), "selectedCapabilityRoots": .array([]),
            "ephemeral": .bool(true), "modelProvider": .string("openai"), "allowProviderModelFallback": .bool(false),
            "baseInstructions": .string("You are AgentDesk's project assistant. Work only with the authorized project context and report evidence and limitations."),
            "developerInstructions": .string(request.instructions), "config": .object(configuration(directory: directory, profile: profile))
        ]
        if let model = request.model { parameters["model"] = .string(model) }
        return .object(parameters)
    }
    static func turnParameters(request: ExecutionRequest, directory: URL, profile: String, thread: String) throws -> CodexJSONValue {
        var parameters: [String: CodexJSONValue] = [
            "threadId": .string(thread), "cwd": .string(directory.path), "permissions": .string(profile),
            "runtimeWorkspaceRoots": .array([.string(directory.path)]),
            "approvalPolicy": .string("never"),
            "input": .array([.object(["type": .string("text"), "text": .string(request.task)])])
        ]
        if let model = request.model { parameters["model"] = .string(model) }
        if let schema = request.outputSchema { parameters["outputSchema"] = try JSONDecoder().decode(CodexJSONValue.self, from: schema.jsonData()) }
        return .object(parameters)
    }
    static func request(_ id: Int64, _ method: String, _ parameters: CodexJSONValue) -> CodexJSONValue {
        .object(["id": .integer(id), "method": .string(method), "params": parameters])
    }
    static var initialize: CodexJSONValue {
        request(1, "initialize", .object([
            "clientInfo": .object(["name": .string("agentdesk"), "title": .string("AgentDesk"), "version": .string("0.1")]),
            // Needed for explicit named permissions and runtime roots in the installed CLI protocol.
            "capabilities": .object(["experimentalApi": .bool(true)])
        ]))
    }
}
#endif
