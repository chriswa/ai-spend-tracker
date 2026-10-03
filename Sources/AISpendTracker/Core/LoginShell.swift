import Foundation

/// The user's login-shell `PATH`. A menu-bar app launched from Finder inherits a bare
/// `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), which misses `~/.local/bin`, Homebrew, and
/// nvm/asdf/volta-style installs — and with them any CLI we shell out to, plus the
/// interpreter named in its shebang (`#!/usr/bin/env bun`).
///
/// The shell runs as an *interactive* login shell (`-lic`): zsh reads `.zshrc` only
/// when interactive, and that is where many setups extend `PATH`.
enum LoginShell {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPATH: String?

    /// `PATH` as the user's login shell sets it, or nil if the shell couldn't be run.
    /// Cached once found; a miss is not cached, so a transient failure retries.
    static func path() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cachedPATH { return cachedPATH }
        cachedPATH = run(#"printf %s "$PATH""#)
        return cachedPATH
    }

    /// Absolute path of `name` on the login-shell `PATH`, or nil.
    static func which(_ name: String) -> URL? {
        guard let path = path() else { return nil }
        let fm = FileManager.default
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Markers bracketing the command's output, since interactive rc files may print
    /// their own text to stdout.
    private static let begin = "__AIST_BEGIN__", end = "__AIST_END__"

    private static func run(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lic", "printf %s \(begin); \(command); printf %s \(end)"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        // Read before waiting: a login shell can emit more than fits the pipe buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8),
              let start = output.range(of: begin),
              let stop = output.range(of: end, range: start.upperBound..<output.endIndex)
        else { return nil }
        let text = output[start.upperBound..<stop.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
