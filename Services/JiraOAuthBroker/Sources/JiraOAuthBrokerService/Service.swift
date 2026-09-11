import Darwin
import Foundation
import JiraOAuthBroker

@main struct Service {
    static func main() async {
        do {
            // Require a deployment pipe/file, never a command-line secret or interactive echo.
            guard isatty(STDIN_FILENO) == 0 else { throw BrokerError.invalidRequest }
            var input = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
                input.append(chunk)
                guard input.count <= 32_770 else { throw BrokerError.invalidRequest }
            }
            let config = try BrokerServiceConfiguration(environment: ProcessInfo.processInfo.environment, secretInput: input)
            let exchange = try AtlassianTokenExchange(clientID: config.clientID, clientSecret: config.clientSecret, callback: config.callback)
            let attempts = try BrokerAttempts(clientID: config.clientID, callback: config.callback)
            let router = try BrokerRouter(attempts: attempts, callbackPath: config.callback.path, exchange: exchange)
            let server = BrokerServer(router: router)
            let signals = AsyncStream<Void>.makeStream()
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let sources = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { @Sendable in signals.continuation.yield(()) }
                source.resume()
                return source
            }
            let expiry = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))
                        await attempts.expirePending()
                    }
                } catch { }
            }
            do {
                let port = try await server.start(port: config.port)
                print("Jira OAuth broker listening on 127.0.0.1:\(port)")
                for await _ in signals.stream { break }
            } catch {
                expiry.cancel(); await expiry.value
                await server.stop(); await exchange.close(); await attempts.shutdown()
                for source in sources { source.cancel() }
                throw error
            }
            expiry.cancel(); await expiry.value
            await server.stop(); await exchange.close(); await attempts.shutdown()
            for source in sources { source.cancel() }
            signals.continuation.finish()
        } catch {
            // Never print arbitrary errors: deployment inputs can contain credentials.
            FileHandle.standardError.write(Data("Jira OAuth broker startup or runtime failure. Check deployment configuration.\n".utf8))
            exit(1)
        }
    }
}
