#if os(macOS)
import AgentDeskSecurity
import Foundation

/// Internal read-only adapter. A project-authorized caller supplies the repository root and run context.
/// No commit, reset, clean, index update, arbitrary Git command or remote operation is exposed.
actor GitRepositoryCapture: RunRepositoryCapturing {
    nonisolated let context: RedactionContext
    nonisolated let resource: ExecutionResource
    private struct Version: Equatable {
        let entry: GitStatusEntry
        let head: GitWorkingFile
        let index: GitWorkingFile
        let working: GitWorkingFile
    }
    private struct Observation: Equatable {
        let status: GitStatus
        let versions: [Version]
        let baselineFiles: [String: GitWorkingFile]
        let configuration: Data
    }
    private struct FileSummary: Encodable {
        let path: String
        let originalPath: String?
        let status: String
        let kind: String
        let workingTreeKind: String
        let comparison: String
        let preexistingDirty: Bool
    }
    private struct Snapshot: Encodable {
        let head: String?
        let branch: String
        let phase: String
        let files: [FileSummary]
        let attribution = "Observed changes; authorship is not inferred."
        let submoduleContentsInspected = false
    }
    private let files: GitRepositoryFiles
    private let executable: URL
    private let redactor: ContentRedactor
    private var baseline: Observation?
    private var active = false
    private let clock = ContinuousClock()
    private static let missing = GitWorkingFile(kind: .missing, digest: nil, text: nil)
    private static let environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_ATTR_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1",
        "GIT_NO_REPLACE_OBJECTS": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "GIT_LITERAL_PATHSPECS": "1"]

    init(root: URL, context: RedactionContext, redactor: ContentRedactor) throws {
        guard redactor.context == context else { throw RepositoryCaptureError.scopeMismatch }
        files = try GitRepositoryFiles(root: root); executable = try GitExecutableLocator.installed(); self.redactor = redactor
        self.context = context; resource = try files.resource(in: context.scope)
    }
    func captureBaseline() async throws -> RepositoryEvidence {
        guard !active else { throw RepositoryCaptureError.busy }
        guard baseline == nil else { throw RepositoryCaptureError.changedBaseline }
        active = true; defer { active = false }
        let observation = try await stableObservation()
        let evidence = try evidence(observation, before: nil)
        baseline = observation
        return evidence
    }
    func captureChanges() async throws -> RepositoryEvidence {
        guard !active else { throw RepositoryCaptureError.busy }
        guard let baseline else { throw RepositoryCaptureError.missingBaseline }
        active = true; defer { active = false }
        let current = try await stableObservation()
        guard current.status.head == baseline.status.head, current.status.branch == baseline.status.branch,
              current.configuration == baseline.configuration else { throw RepositoryCaptureError.changedBaseline }
        return try evidence(current, before: baseline)
    }

    private func stableObservation() async throws -> Observation {
        let deadline = clock.now + .seconds(30)
        let metadata = try files.metadataFingerprint(), configuration = try files.configuration()
        let output = try await execute(["--no-pager", "config", "--file", files.root.appendingPathComponent(".git/config").path,
                                        "--no-includes", "--null", "--list"], directory: URL(fileURLWithPath: "/"), deadline: deadline)
        let options = try GitCaptureConfiguration.overrides(configuration: output)
        // This command exposes entries Git would otherwise intentionally omit from normal status.
        try GitCaptureConfiguration.validateIndexFlags(await command(["ls-files", "-v", "-z"], options: options, configuration: configuration, deadline: deadline))
        let first = try await observe(options: options, configuration: configuration, deadline: deadline)
        let second = try await observe(options: options, configuration: configuration, deadline: deadline)
        guard first == second, try files.metadataFingerprint() == metadata else { throw RepositoryCaptureError.changedDuringCapture }
        guard clock.now < deadline else { throw RepositoryCaptureError.timedOut }
        return second
    }
    private func observe(options: [String], configuration: Data, deadline: ContinuousClock.Instant) async throws -> Observation {
        let raw = try await command(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignore-submodules=all"],
                                    options: options, configuration: configuration, deadline: deadline)
        let status = try GitStatusParser.parse(raw)
        var versions: [Version] = [], cache: [String: GitWorkingFile] = [:], bytes = 0
        for entry in status.entries {
            try Task.checkCancellation()
            let working: GitWorkingFile
            if entry.metadata.contains("160000") { working = .init(kind: .submodule, digest: nil, text: nil) }
            else { working = try files.workingFile(entry.path) }
            var head = Self.missing, index = Self.missing
            if (entry.kind == .tracked || entry.kind == .renamed) && working.kind != .submodule {
                head = try await blob(entry.metadata[4], cache: &cache, options: options, configuration: configuration, deadline: deadline)
                index = try await blob(entry.metadata[5], cache: &cache, options: options, configuration: configuration, deadline: deadline)
            }
            bytes += head.text?.utf8.count ?? 0
            bytes += index.text?.utf8.count ?? 0
            bytes += working.text?.utf8.count ?? 0
            guard bytes <= 262_144 else { throw RepositoryCaptureError.limitExceeded }
            versions.append(Version(entry: entry, head: head, index: index, working: working))
        }
        let visible = Set(status.entries.map(\.path))
        var baselineFiles: [String: GitWorkingFile] = [:]
        for old in baseline?.versions ?? [] where !visible.contains(old.entry.path) {
            let current = try files.workingFile(old.entry.path)
            bytes += current.text?.utf8.count ?? 0
            guard bytes <= 262_144 else { throw RepositoryCaptureError.limitExceeded }
            baselineFiles[old.entry.path] = current
        }
        return Observation(status: status, versions: versions, baselineFiles: baselineFiles, configuration: configuration)
    }
    private func blob(_ id: String, cache: inout [String: GitWorkingFile], options: [String], configuration: Data,
                      deadline: ContinuousClock.Instant) async throws -> GitWorkingFile {
        if id.allSatisfy({ $0 == "0" }) { return Self.missing }
        if let cached = cache[id] { return cached }
        let count = try await command(["cat-file", "-s", id], options: options, configuration: configuration, deadline: deadline)
        guard let countText = String(data: count, encoding: .utf8), countText.utf8.count <= 30,
              let size = Int(countText.trimmingCharacters(in: .newlines)), size >= 0 else { throw RepositoryCaptureError.malformedOutput }
        if size > 65_536 { let value = GitWorkingFile(kind: .tooLarge, digest: nil, text: nil); cache[id] = value; return value }
        let data = try await command(["cat-file", "blob", id], options: options, configuration: configuration, deadline: deadline)
        guard data.count == size else { throw RepositoryCaptureError.changedDuringCapture }
        let text = data.contains(0) ? nil : String(data: data, encoding: .utf8)
        // The immutable Git object ID is only an in-memory comparison key, never a raw-content digest export.
        let value = GitWorkingFile(kind: text == nil ? .binary : .text, digest: Data(id.utf8), text: text)
        cache[id] = value; return value
    }
    private func command(_ arguments: [String], options: [String], configuration: Data,
                         deadline: ContinuousClock.Instant) async throws -> Data {
        try files.validateRoot()
        guard try files.configuration() == configuration else { throw RepositoryCaptureError.changedDuringCapture }
        return try await execute(["--no-pager", "--git-dir=" + files.root.appendingPathComponent(".git").path,
                                  "--work-tree=" + files.root.path] + options + arguments, directory: files.root, deadline: deadline)
    }
    private func execute(_ arguments: [String], directory: URL, deadline: ContinuousClock.Instant) async throws -> Data {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw RepositoryCaptureError.timedOut }
        do {
            let output = try await MacCommandCapture.run(executable: executable, arguments: arguments,
                directory: directory, environment: Self.environment, timeout: clock.now.duration(to: deadline), maximumBytes: 262_144)
            guard output.status == 0 else { throw RepositoryCaptureError.commandFailed }
            try files.validateRoot()
            return output.stdout
        } catch is CancellationError { throw CancellationError() }
        catch CodexDiagnosticIssue.timedOut { throw RepositoryCaptureError.timedOut }
        catch CodexDiagnosticIssue.outputLimit { throw RepositoryCaptureError.limitExceeded }
        catch let error as RepositoryCaptureError { throw error }
        catch { throw RepositoryCaptureError.commandFailed }
    }

    private func evidence(_ current: Observation, before: Observation?) throws -> RepositoryEvidence {
        let prior = Dictionary(uniqueKeysWithValues: (before?.versions ?? []).map { ($0.entry.path, $0) })
        var summaries: [FileSummary] = [], preview = "", classification = EvidenceClassification.internalData, usedPrior = Set<String>()
        for version in current.versions {
            let old = prior[version.entry.path] ?? version.entry.originalPath.flatMap { prior[$0] }
            if let old { usedPrior.insert(old.entry.path) }
            let comparison: String
            if before == nil { comparison = "baseline" }
            else if version.working.kind == .tooLarge || old?.working.kind == .tooLarge || version.working.kind == .submodule { comparison = "indeterminate" }
            else if let old { comparison = old == version ? "unchangedPreexisting" : "changedSinceBaseline" }
            else { comparison = "newlyChanged" }
            summaries.append(FileSummary(path: version.entry.path, originalPath: version.entry.originalPath, status: version.entry.status,
                kind: version.entry.kind.rawValue, workingTreeKind: version.working.kind.rawValue, comparison: comparison, preexistingDirty: before == nil || old != nil))
            if version.entry.kind == .unmerged {
                preview += "Unmerged index for \(try label(version.entry.path)); staged preview unavailable.\n"
            } else {
                preview += try diff(version.head, version.index, path: version.entry.path, oldPath: version.entry.originalPath,
                                    title: "HEAD to index", classification: &classification)
                preview += try diff(version.index, version.working, path: version.entry.path, title: "Index to working tree", classification: &classification)
            }
            if before != nil, let old {
                preview += try diff(old.working, version.working, path: version.entry.path, oldPath: old.entry.path,
                                    title: "Run baseline to working tree", classification: &classification)
            }
            guard preview.utf8.count <= 262_144 else { throw RepositoryCaptureError.limitExceeded }
        }
        // A preexisting entry can leave status because it was restored, removed or newly ignored.
        // Its current content was observed in both stability passes; do not infer why it disappeared.
        for old in (before?.versions ?? []) where !usedPrior.contains(old.entry.path) {
            guard let working = current.baselineFiles[old.entry.path] else { throw RepositoryCaptureError.changedDuringCapture }
            summaries.append(FileSummary(path: old.entry.path, originalPath: old.entry.originalPath, status: "..", kind: old.entry.kind.rawValue,
                workingTreeKind: working.kind.rawValue, comparison: "noLongerInStatus", preexistingDirty: true))
            preview += try diff(old.working, working, path: old.entry.path, title: "Run baseline to working tree", classification: &classification)
            guard preview.utf8.count <= 262_144 else { throw RepositoryCaptureError.limitExceeded }
        }
        let snapshot = Snapshot(head: current.status.head, branch: current.status.branch, phase: before == nil ? "baseline" : "current", files: summaries)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        return RepositoryEvidence(snapshot: try redactor.redactJSON(json, in: redactor.context),
            diff: try redactor.redactText(preview, in: redactor.context, classification: classification))
    }
    private func diff(_ before: GitWorkingFile, _ after: GitWorkingFile, path: String, oldPath: String? = nil,
                      title: String, classification: inout EvidenceClassification) throws -> String {
        if before == after { return "" }
        guard [.text, .missing].contains(before.kind), [.text, .missing].contains(after.kind) else {
            return "\(title): \(try label(path)) — preview unavailable (\(before.kind.rawValue) to \(after.kind.rawValue)).\n"
        }
        let old = try redactor.redactText(before.text ?? "", in: redactor.context)
        let new = try redactor.redactText(after.text ?? "", in: redactor.context)
        if old.classification == .confidential || new.classification == .confidential { classification = .confidential }
        let body = try RepositoryTextDiff.render(before: old.text, after: new.text, oldLabel: label(oldPath ?? path), newLabel: label(path))
        if body.isEmpty && before.text != after.text { return "\(title): \(try label(path)) — contents differ; sanitized previews are identical.\n" }
        return body.isEmpty ? "" : "\(title)\n" + body
    }
    private func label(_ path: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(path), as: UTF8.self)
    }
}
#endif
