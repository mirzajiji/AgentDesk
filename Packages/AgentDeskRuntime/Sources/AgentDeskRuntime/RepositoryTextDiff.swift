import Foundation

/// A bounded deterministic unified preview. Callers sanitize both source texts before diffing.
/// This preview may contain redaction markers and is never an apply/patch authority.
enum RepositoryTextDiff {
    private struct Line: Equatable { let text: String; let hasNewline: Bool }
    static func render(before: String, after: String, oldLabel: String, newLabel: String) throws -> String {
        try Task.checkCancellation()
        guard before.utf8.count <= 262_144, after.utf8.count <= 262_144,
              oldLabel.utf8.count <= 32_768, newLabel.utf8.count <= 32_768 else { throw RepositoryCaptureError.limitExceeded }
        if before == after { return "" }
        let old = lines(before), new = lines(after)
        guard old.count <= 1_024, new.count <= 1_024 else { throw RepositoryCaptureError.limitExceeded }
        let width = new.count + 1
        var lengths = [UInt16](repeating: 0, count: (old.count + 1) * width)
        for i in old.indices.reversed() {
            try Task.checkCancellation()
            for j in new.indices.reversed() {
                lengths[i * width + j] = old[i] == new[j] ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        let oldStart = old.isEmpty ? 0 : 1, newStart = new.isEmpty ? 0 : 1
        var output = "--- \(oldLabel)\n+++ \(newLabel)\n@@ -\(oldStart),\(old.count) +\(newStart),\(new.count) @@\n"
        var i = 0, j = 0
        func append(_ prefix: String, _ line: Line) {
            output += prefix + line.text + "\n"
            if !line.hasNewline { output += "\\ No newline at end of file\n" }
        }
        while i < old.count || j < new.count {
            try Task.checkCancellation()
            if i < old.count, j < new.count, old[i] == new[j] { append(" ", old[i]); i += 1; j += 1 }
            else if i < old.count, j == new.count || lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                append("-", old[i]); i += 1
            } else { append("+", new[j]); j += 1 }
            guard output.utf8.count <= 262_144 else { throw RepositoryCaptureError.limitExceeded }
        }
        return output
    }
    private static func lines(_ value: String) -> [Line] {
        guard !value.isEmpty else { return [] }
        let parts = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return parts.enumerated().compactMap { index, text in
            if index == parts.count - 1 && text.isEmpty { return nil }
            return Line(text: text, hasNewline: index < parts.count - 1)
        }
    }
}
