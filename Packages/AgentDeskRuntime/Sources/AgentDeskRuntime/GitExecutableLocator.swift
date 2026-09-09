#if os(macOS)
import Darwin
import Foundation

/// /usr/bin/git is an xcrun shim, which explicitly cannot run in App Sandbox. Use the installed
/// Apple Git binary directly; it still inherits the main app's sandbox and filesystem permissions.
enum GitExecutableLocator {
    static func installed() throws -> URL {
        try Task.checkCancellation()
        for path in ["/Applications/Xcode.app/Contents/Developer/usr/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git"] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_mode & 0o111 != 0, FileManager.default.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        throw RepositoryCaptureError.gitUnavailable
    }
}
#endif
