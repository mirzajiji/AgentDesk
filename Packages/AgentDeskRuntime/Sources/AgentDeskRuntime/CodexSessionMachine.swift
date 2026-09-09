#if os(macOS)
import Foundation

/// One ephemeral read-only turn. Every accepted notification is bound to its returned thread/turn identities.
struct CodexSessionMachine: Sendable {
    private enum Phase { case initializing, creatingThread, startingTurn, running, complete }
    private var phase = Phase.initializing
    private var framer: CodexJSONLineFramer
    private var thread: String?
    private var turn: String?
    private var turnResponseReceived = false
    private var sequence: Int64 = 0
    private var items: [String: (kind: String, completed: Bool)] = [:]
    private var textBytes = 0
    private var finalText: String?
    private let request: ExecutionRequest
    private let directory: URL
    let profile: String

    init(request: ExecutionRequest, directory: URL, profile: String) throws {
        self.request = request; self.directory = directory; self.profile = profile
        framer = try CodexJSONLineFramer()
    }
    mutating func accept(_ bytes: Data, input: MacProcessInputPipe,
                         emit: (ExecutionProviderEvent) throws -> Void) throws {
        for record in try framer.append(bytes) { try receive(CodexJSONValue.decodeMessage(record), input: input, emit: emit) }
    }
    mutating func finish(input: MacProcessInputPipe, emit: (ExecutionProviderEvent) throws -> Void) throws {
        for record in try framer.finish() { try receive(CodexJSONValue.decodeMessage(record), input: input, emit: emit) }
        guard phase == .complete, turnResponseReceived, let text = finalText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExecutionProviderError.incompleteResult
        }
        try publish(.completed(text: text), emit: emit)
    }
    private mutating func receive(_ message: [String: CodexJSONValue], input: MacProcessInputPipe,
                                  emit: (ExecutionProviderEvent) throws -> Void) throws {
        if message["id"] != nil {
            // Server requests would require a separate exact-action policy/approval path. Fail closed here.
            guard message["method"] == nil else { throw ExecutionProviderError.unexpectedApproval }
            guard message["error"] == nil || message["error"] == .null,
                  let id = message["id"]?.integer, let result = message["result"]?.object else { throw ExecutionProviderError.invalidProtocol }
            switch (phase, id) {
            case (.initializing, 1):
                phase = .creatingThread
                try input.write(CodexJSONValue.object(["method": .string("initialized")]).line())
                try input.write(CodexExecutionConfiguration.request(2, "thread/start", CodexExecutionConfiguration.threadParameters(request: request, directory: directory, profile: profile)).line())
            case (.creatingThread, 2):
                guard result["cwd"]?.string == directory.path, result["approvalPolicy"]?.string == "never",
                      result["modelProvider"]?.string == "openai",
                      result["activePermissionProfile"]?["id"]?.string == profile,
                      result["activePermissionProfile"]?["extends"] == nil || result["activePermissionProfile"]?["extends"] == .null,
                      result["runtimeWorkspaceRoots"]?.array == [.string(directory.path)],
                      result["sandbox"]?["type"]?.string == "readOnly", result["sandbox"]?["networkAccess"]?.bool == false,
                      result["thread"]?["ephemeral"]?.bool == true else { throw ExecutionProviderError.unverifiedPermissions }
                if let selected = request.model, result["model"]?.string != selected { throw ExecutionProviderError.unverifiedPermissions }
                thread = try identifier(result["thread"]?["id"])
                phase = .startingTurn
                try input.write(CodexExecutionConfiguration.request(3, "turn/start", CodexExecutionConfiguration.turnParameters(request: request, directory: directory, profile: profile, thread: thread!)).line())
            case (.startingTurn, 3), (.running, 3), (.complete, 3):
                guard !turnResponseReceived else { throw ExecutionProviderError.invalidProtocol }
                try bindTurn(result["turn"]?["id"])
                turnResponseReceived = true
            default: throw ExecutionProviderError.invalidProtocol
            }
            return
        }
        guard let method = message["method"]?.string, method.utf8.count <= 128 else { throw ExecutionProviderError.invalidProtocol }
        // Initialization/status notifications are not task results and never contribute text.
        guard ["turn/started", "turn/completed", "item/started", "item/completed", "error"].contains(method) else { return }
        guard let params = message["params"]?.object, let expectedThread = thread,
              params["threadId"]?.string == expectedThread else { throw ExecutionProviderError.scopeMismatch }
        if method == "error" { throw ExecutionProviderError.providerFailed }
        switch method {
        case "turn/started":
            guard phase == .startingTurn else { throw ExecutionProviderError.invalidProtocol }
            try bindTurn(params["turn"]?["id"]); phase = .running
            try publish(.started, emit: emit)
        case "turn/completed":
            guard phase == .running else { throw ExecutionProviderError.invalidProtocol }
            try bindTurn(params["turn"]?["id"])
            guard params["turn"]?["status"]?.string == "completed",
                  params["turn"]?["error"] == nil || params["turn"]?["error"] == .null else { throw ExecutionProviderError.providerFailed }
            guard items.values.allSatisfy(\.completed), finalText != nil else { throw ExecutionProviderError.incompleteResult }
            phase = .complete; input.close()
        case "item/started", "item/completed":
            guard phase == .running, params["turnId"]?.string == turn,
                  let item = params["item"]?.object, let kind = item["type"]?.string else { throw ExecutionProviderError.scopeMismatch }
            // Reasoning payloads and user-message echoes are deliberately not exposed as output.
            if kind == "reasoning" || kind == "userMessage" { return }
            guard ["agentMessage", "commandExecution", "fileChange", "plan"].contains(kind) else { throw ExecutionProviderError.invalidProtocol }
            let id = try identifier(item["id"]), completed = method == "item/completed"
            if let prior = items[id] {
                guard prior.kind == kind, !prior.completed, completed else { throw ExecutionProviderError.invalidProtocol }
            } else { guard items.count < request.maximumActivities else { throw ExecutionProviderError.outputLimit } }
            items[id] = (kind, completed)
            if kind == "agentMessage" {
                if completed {
                    guard let text = item["text"]?.string, !text.utf8.contains(0), text.utf8.count <= 262_144 - textBytes else { throw ExecutionProviderError.outputLimit }
                    textBytes += text.utf8.count
                    let messagePhase = item["phase"]?.string
                    guard messagePhase == nil || ["commentary", "final_answer"].contains(messagePhase!) else { throw ExecutionProviderError.invalidProtocol }
                    if messagePhase != "commentary" { finalText = text }
                    try publish(.message(id: id, text: text), emit: emit)
                }
            } else {
                // A read-only provider never accepts a file mutation as an authorized success.
                guard kind != "fileChange" else { throw ExecutionProviderError.unverifiedPermissions }
                if kind == "commandExecution" {
                    guard let cwd = item["cwd"]?.string, cwd.hasPrefix("/"), !cwd.utf8.contains(0), cwd.utf8.count <= 4_096 else { throw ExecutionProviderError.scopeMismatch }
                    let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
                    guard resolved == directory.path || resolved.hasPrefix(directory.path + "/") else { throw ExecutionProviderError.scopeMismatch }
                }
                try publish(.activity(id: id, kind: kind == "commandExecution" ? .command : .planning, completed: completed), emit: emit)
            }
        default: break
        }
    }
    private func identifier(_ value: CodexJSONValue?) throws -> String {
        guard let value = value?.string, !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-:".unicodeScalars.contains($0) }) else { throw ExecutionProviderError.invalidProtocol }
        return value
    }
    private mutating func bindTurn(_ value: CodexJSONValue?) throws {
        let id = try identifier(value)
        guard turn == nil || turn == id else { throw ExecutionProviderError.scopeMismatch }
        turn = id
    }
    private mutating func publish(_ payload: ExecutionProviderEvent.Payload, emit: (ExecutionProviderEvent) throws -> Void) throws {
        sequence += 1
        try emit(ExecutionProviderEvent(identity: request.identity, sequence: sequence, payload: payload))
    }
}
#endif
