import AgentDeskRuntime
import Foundation

final class CodexHostEndpoint: NSObject, CodexHostXPC {
    let session: CodexHostSession
    init(session: CodexHostSession) { self.session = session }
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let session = session
        Task { reply(await session.perform(request)) }
    }
}

final class CodexHostListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The system validates each message against the exact app identity and development team.
        connection.setCodeSigningRequirement(CodexHostContract.clientRequirement)
        let session = CodexHostSession()
        connection.exportedInterface = NSXPCInterface(with: CodexHostXPC.self)
        connection.exportedObject = CodexHostEndpoint(session: session)
        connection.invalidationHandler = { Task { await session.invalidate() } }
        connection.interruptionHandler = { Task { await session.invalidate() } }
        connection.activate()
        return true
    }
}

let delegate = CodexHostListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
