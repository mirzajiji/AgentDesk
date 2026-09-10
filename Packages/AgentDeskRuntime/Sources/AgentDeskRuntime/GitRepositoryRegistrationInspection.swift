#if os(macOS)
import AgentDeskCore
import Foundation

/// Verifies the selected directory is the actual worktree root without invoking configured hooks/helpers.
/// Full dirty status and source/diff collection remain run-time evidence operations.
enum GitRepositoryRegistrationInspection {
    static func inspect(root: URL, scope: ProjectScope) async throws -> ExecutionResource {
        let files = try GitRepositoryFiles(root: root), executable = try GitExecutableLocator.installed()
        let metadata = try files.metadataFingerprint(), configuration = try files.configuration()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let parsed = try await command(["config", "--null", "--list", "--file", files.root.appendingPathComponent(".git/config").path,
            "--no-includes"], directory: URL(fileURLWithPath: "/"), executable: executable, deadline: deadline)
        let options = try GitCaptureConfiguration.overrides(configuration: parsed)
        try files.validateRoot()
        guard try files.configuration() == configuration else { throw RepositoryRegistrationError.changedDirectory }
        let result = try await command(["--no-pager", "--git-dir=" + files.root.appendingPathComponent(".git").path,
            "--work-tree=" + files.root.path] + options + ["rev-parse", "--is-inside-work-tree", "--show-toplevel"],
            directory: files.root, executable: executable, deadline: deadline)
        guard let text = String(data: result, encoding: .utf8), text == "true\n" + files.root.path + "\n",
              try files.configuration() == configuration, try files.metadataFingerprint() == metadata else {
            throw RepositoryRegistrationError.invalidSelection
        }
        return try files.resource(in: scope)
    }
    private static func command(_ arguments: [String], directory: URL, executable: URL, deadline: ContinuousClock.Instant) async throws -> Data {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw RepositoryRegistrationError.unavailable }
        let result = try await MacCommandCapture.run(executable: executable, arguments: arguments, directory: directory,
            environment: GitCaptureConfiguration.environment, timeout: ContinuousClock.now.duration(to: deadline), maximumBytes: 65_536)
        guard result.status == 0 else { throw RepositoryRegistrationError.invalidSelection }
        return result.stdout
    }
}
#endif
