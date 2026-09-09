import Foundation

enum RepositoryCaptureError: Error, Equatable, Sendable {
    case invalidRepository, unsupportedRepository, gitUnavailable, unsafeFile, malformedOutput, limitExceeded
    case changedDuringCapture, changedBaseline, missingBaseline, scopeMismatch, commandFailed, timedOut, busy
    case fileSystem(Int32)
}
struct GitStatusEntry: Equatable, Sendable {
    enum Kind: String, Sendable { case tracked, renamed, unmerged, untracked }
    let kind: Kind
    let status: String
    let path: String
    let originalPath: String?
    let metadata: [String]
}
struct GitStatus: Equatable, Sendable {
    let head: String?
    let branch: String
    let entries: [GitStatusEntry]
}

/// Porcelain v2 with NUL separators. Paths may contain spaces, tabs and newlines, but not traversal.
enum GitStatusParser {
    static func parse(_ data: Data) throws -> GitStatus {
        guard data.count <= 262_144, data.last == 0, let text = String(data: data, encoding: .utf8) else {
            throw RepositoryCaptureError.malformedOutput
        }
        let records = text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        var entries: [GitStatusEntry] = [], headers: [String: String] = [:], index = 0, paths = Set<String>()
        while index < records.count {
            try Task.checkCancellation()
            let record = records[index]; index += 1
            if record.hasPrefix("# ") {
                let fields = record.dropFirst(2).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2, !fields[1].isEmpty, fields[1].utf8.count <= 1_024,
                      headers.count < 16, headers.updateValue(String(fields[1]), forKey: String(fields[0])) == nil else { throw RepositoryCaptureError.malformedOutput }
                continue
            }
            let entry: GitStatusEntry
            if record.hasPrefix("? ") {
                entry = GitStatusEntry(kind: .untracked, status: "??", path: String(record.dropFirst(2)), originalPath: nil, metadata: [])
            } else {
                let splitCount: Int
                switch record.first { case "1": splitCount = 8; case "2": splitCount = 9; case "u": splitCount = 10; default: throw RepositoryCaptureError.malformedOutput }
                let fields = record.split(separator: " ", maxSplits: splitCount, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == splitCount + 1, ["1", "2", "u"].contains(fields[0]), fields.dropLast().allSatisfy({ !$0.isEmpty }),
                      fields[1].utf8.count == 2, fields[1].utf8.allSatisfy({ Array(".MADRCUT".utf8).contains($0) }),
                      fields[2] == "N..." || (fields[2].utf8.count == 4 && fields[2].first == "S" && zip(fields[2].dropFirst(), "CMU").allSatisfy({ pair in pair.0 == "." || pair.0 == pair.1 })) else {
                    throw RepositoryCaptureError.malformedOutput
                }
                let modes = fields[0] == "u" ? 3...6 : 3...5
                let hashes = fields[0] == "u" ? 7...9 : 6...7
                guard modes.allSatisfy({ fields[$0].utf8.count == 6 && fields[$0].utf8.allSatisfy { (48...55).contains($0) } }),
                      hashes.allSatisfy({ objectID(fields[$0]) }) else { throw RepositoryCaptureError.malformedOutput }
                var original: String?
                if fields[0] == "2" {
                    guard let prefix = fields[8].first, prefix == "R" || prefix == "C",
                          let score = Int(fields[8].dropFirst()), (0...100).contains(score), index < records.count else {
                        throw RepositoryCaptureError.malformedOutput
                    }
                    original = records[index]; index += 1
                    try validatePath(original!)
                }
                entry = GitStatusEntry(kind: fields[0] == "u" ? .unmerged : fields[0] == "2" ? .renamed : .tracked,
                                       status: fields[1], path: fields.last!, originalPath: original, metadata: Array(fields[2..<splitCount]))
            }
            try validatePath(entry.path)
            guard paths.insert(entry.path).inserted, entries.count < 128 else { throw RepositoryCaptureError.limitExceeded }
            entries.append(entry)
        }
        guard let oid = headers["branch.oid"], oid == "(initial)" || objectID(oid), let branch = headers["branch.head"] else {
            throw RepositoryCaptureError.malformedOutput
        }
        return GitStatus(head: oid == "(initial)" ? nil : oid, branch: branch, entries: entries.sorted { $0.path < $1.path })
    }
    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.utf8.contains(0), parts.count <= 64,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw RepositoryCaptureError.unsafeFile
        }
    }
    private static func objectID(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
