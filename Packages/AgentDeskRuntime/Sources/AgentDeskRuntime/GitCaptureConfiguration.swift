import Foundation

enum GitCaptureConfiguration {
    static let environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_ATTR_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1",
        "GIT_NO_REPLACE_OBJECTS": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "GIT_LITERAL_PATHSPECS": "1"]
    // Git's --null config output separates each key/value with a newline and records with NUL.
    // This input comes from --file <validated config> --no-includes outside any repository.
    static func overrides(configuration data: Data) throws -> [String] {
        guard data.count <= 65_536, data.isEmpty || data.last == 0, let text = String(data: data, encoding: .utf8) else {
            throw RepositoryCaptureError.malformedOutput
        }
        var filters = Set<String>()
        let entries = text.split(separator: "\0", omittingEmptySubsequences: false).dropLast()
        guard entries.count <= 1_024 else { throw RepositoryCaptureError.limitExceeded }
        for entry in entries {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty, key.utf8.count <= 256 else { throw RepositoryCaptureError.malformedOutput }
            let lower = key.lowercased()
            guard !lower.hasPrefix("include."), !lower.hasPrefix("includeif."), !lower.hasPrefix("extensions."),
                  !lower.hasSuffix(".promisor"), lower != "core.repositoryformatversion" || (parts.count == 2 && parts[1] == "0") else {
                throw RepositoryCaptureError.unsupportedRepository
            }
            if lower.hasPrefix("filter.") {
                guard let final = key.lastIndex(of: "."), final > key.index(key.startIndex, offsetBy: 6) else {
                    throw RepositoryCaptureError.malformedOutput
                }
                filters.insert(String(key[..<final]))
            }
        }
        guard filters.count <= 8 else { throw RepositoryCaptureError.limitExceeded }
        let fixed = ["core.fsmonitor=false", "core.hooksPath=/dev/null", "core.attributesFile=/dev/null", "core.excludesFile=/dev/null",
                     "core.bare=false", "core.quotePath=false", "status.submoduleSummary=false", "status.renames=true",
                     "gc.auto=0", "maintenance.auto=false", "core.untrackedCache=false", "credential.helper=",
                     "diff.external=", "diff.orderFile=/dev/null"]
        let disabled = filters.sorted().flatMap { ["\($0).clean=", "\($0).smudge=", "\($0).process=", "\($0).required=false"] }
        return (fixed + disabled).flatMap { ["-c", $0] }
    }
    static func validateIndexFlags(_ data: Data) throws {
        guard data.count <= 262_144, data.isEmpty || data.last == 0, let text = String(data: data, encoding: .utf8) else {
            throw RepositoryCaptureError.malformedOutput
        }
        for record in text.split(separator: "\0", omittingEmptySubsequences: true) {
            // Lowercase flags hide assume-unchanged entries; S hides skip-worktree entries.
            guard record.hasPrefix("H ") || record.hasPrefix("M ") || record.hasPrefix("R ") || record.hasPrefix("C ") || record.hasPrefix("K ") || record.hasPrefix("? ") else {
                throw RepositoryCaptureError.unsupportedRepository
            }
            try GitStatusParser.validatePath(String(record.dropFirst(2)))
        }
    }
}
