import AgentDeskRuntime
import Foundation

final class CodexHostEndpoint: NSObject, CodexHostXPC {
    let session: CodexHostSession
    let execution: CodexExecutionHostSession
    init(session: CodexHostSession, execution: CodexExecutionHostSession) { self.session = session; self.execution = execution }
    func execute(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let execution = execution
        Task { reply(await execution.perform(request)) }
    }
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let session = session
        Task { reply(await session.perform(request)) }
    }
}

final class CodexHostListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The system validates each message against the exact app identity and development team.
        connection.setCodeSigningRequirement(CodexHostContract.clientRequirement)
        let session = CodexHostSession(), execution = CodexExecutionHostSession()
        connection.exportedInterface = NSXPCInterface(with: CodexHostXPC.self)
        connection.exportedObject = CodexHostEndpoint(session: session, execution: execution)
        connection.invalidationHandler = { Task { await session.invalidate(); await execution.invalidate() } }
        connection.interruptionHandler = { Task { await session.invalidate(); await execution.invalidate() } }
        connection.activate()
        return true
    }
}

let delegate = CodexHostListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
