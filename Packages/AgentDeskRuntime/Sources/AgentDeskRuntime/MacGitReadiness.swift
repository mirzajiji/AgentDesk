#if os(macOS)
import Foundation

public enum GitReadinessError: Error { case unavailable }

/// A bounded machine-local health check. It accepts no repository, shell text or user arguments.
public enum MacGitReadiness {
    public static func version() async throws -> String {
        let output = try await MacCommandCapture.run(executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--version"], directory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            timeout: .seconds(5), maximumBytes: 4_096)
        return try parse(output)
    }
    static func parse(_ output: CLICommandOutput) throws -> String {
        guard output.status == 0, let text = String(data: output.stdout, encoding: .utf8) else { throw GitReadinessError.unavailable }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3, words[0] == "git", words[1] == "version",
              words[2].count <= 32, words[2].contains("."),
              words[2].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { throw GitReadinessError.unavailable }
        let components = words[2].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            throw GitReadinessError.unavailable
        }
        return String(words[2])
    }
}
#endif
