import Foundation

/// Refreshes Codex's OAuth token by asking the `codex` CLI to do it, rather than
/// minting one ourselves and writing `~/.codex/auth.json`.
///
/// That distinction is the whole point. `auth.json` is shared mutable state: any
/// number of `codex` processes may be running, and a refresh *rotates* the refresh
/// token, so whoever writes last wins and the losers hold a dead credential. The CLI
/// already arbitrates this (it re-reads the file before refreshing and stands down if
/// another process got there first), so delegating leaves us exactly as safe as one
/// more `codex` process — and never the thing that breaks the others.
///
/// The CLI has no plain `refresh` subcommand (`codex login status` reports the state
/// but never refreshes), so we drive its app-server: newline-delimited JSON-RPC on
/// stdio — `initialize`, the `initialized` notification, then `account/read` with
/// `refreshToken: true`, documented as "requests a proactive token refresh before
/// returning".
///
/// Two behaviours of that endpoint shape the code below:
///   • stdin must stay open until the reply arrives. Closing it early makes the
///     server exit at EOF and abandon the in-flight request (it answers
///     `initialize` and nothing else).
///   • the refresh is *unconditional* — every call performs a token exchange and
///     rotates the refresh token. So this is strictly a repair for an observed 401,
///     never part of the normal polling path.
enum CodexCLIAuth {
    /// No `codex` executable on this machine — nothing to delegate to.
    struct CLINotFound: Error {}
    /// The CLI was found but the refresh didn't complete. `detail` is short enough to
    /// show in the menu.
    struct RefreshFailed: Error { let detail: String }

    /// Generous enough for the round-trip to the OpenAI token endpoint on a slow link,
    /// short enough that a wedged CLI doesn't pin the fetch forever.
    private static let timeout: TimeInterval = 30
    /// JSON-RPC id of the refresh request; the reply carrying it ends the exchange.
    private static let refreshID = 1

    /// Refresh the token, returning once `~/.codex/auth.json` holds a new one.
    /// Throws `CLINotFound` or `RefreshFailed`.
    static func refreshToken() async throws {
        try await Task.detached(priority: .userInitiated) { try runRefresh() }.value
    }

    // MARK: - Driving the app-server

    private static func runRefresh() throws {
        guard let exe = executable() else { throw CLINotFound() }

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["app-server", "--stdio"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        do { try proc.run() } catch {
            throw RefreshFailed(detail: "couldn't launch \(exe.path): \(error.localizedDescription)")
        }
        // Always reap the child: on timeout it is still waiting on our open stdin.
        defer {
            if proc.isRunning { proc.terminate() }
            try? stdin.fileHandleForWriting.close()
        }

        // Drain stderr so a chatty server can't fill the pipe buffer and wedge itself.
        let errHandle = stderr.fileHandleForReading
        DispatchQueue.global().async { _ = try? errHandle.readToEnd() }

        let reply = Reply()
        let outHandle = stdout.fileHandleForReading
        DispatchQueue.global().async { readReply(from: outHandle, into: reply) }

        do {
            for message in requestSequence {
                try stdin.fileHandleForWriting.write(contentsOf: Data(message.utf8))
            }
        } catch {
            // The child died before reading us; its stderr/exit is the real story.
            throw RefreshFailed(detail: "codex app-server closed its input")
        }

        guard let outcome = reply.wait(timeout: timeout) else {
            throw RefreshFailed(detail: "codex app-server didn't respond within \(Int(timeout))s")
        }
        if case .failure(let detail) = outcome { throw RefreshFailed(detail: detail) }
    }

    /// The three newline-terminated messages, in order. Pipelined in one go: the
    /// server processes them sequentially, so we don't need to await `initialize`.
    private static var requestSequence: [String] {
        // `clientInfo` is required by the protocol but only cosmetic — it lands in the
        // app-server's User-Agent.
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let client = #"{"name":"ai-spend-tracker","version":"\#(version)"}"#
        return [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":\#(client)}}"# + "\n",
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"# + "\n",
            #"{"jsonrpc":"2.0","id":\#(refreshID),"method":"account/read","params":{"refreshToken":true}}"# + "\n",
        ]
    }

    /// Read newline-delimited JSON until the reply to `refreshID` shows up, then
    /// hand it to `reply`. Notifications and the `initialize` result stream past first.
    ///
    /// `availableData` is load-bearing: `read(upToCount:)` on a pipe blocks until it
    /// has the *full* requested count (or EOF), so it would sit on a complete reply
    /// waiting for bytes the server has no reason to send. `availableData` returns
    /// whatever has arrived, and empty at EOF.
    private static func readReply(from handle: FileHandle, into reply: Reply) {
        var pending = Data()
        while case let chunk = handle.availableData, !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[(newline + 1)...]
                if let outcome = classify(line: Data(line)) { return reply.finish(outcome) }
            }
        }
        reply.finish(.failure("codex app-server exited without answering"))
    }

    /// `.some` once this line is the reply we're waiting for; `nil` for anything else.
    private static func classify(line: Data) -> Outcome? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (json["id"] as? Int) == refreshID else { return nil }
        if let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "unknown error"
            return .failure(message)
        }
        // A result of any shape means the refresh ran and auth.json was rewritten.
        return json["result"] != nil ? .success : .failure("malformed reply from codex app-server")
    }

    private enum Outcome { case success, failure(String) }

    /// One-shot handoff from the reader thread to the caller.
    private final class Reply: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var outcome: Outcome?

        func finish(_ outcome: Outcome) {
            lock.lock()
            guard self.outcome == nil else { return lock.unlock() }   // first answer wins
            self.outcome = outcome
            lock.unlock()
            semaphore.signal()
        }

        /// The outcome, or `nil` on timeout.
        func wait(timeout: TimeInterval) -> Outcome? {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            return outcome
        }
    }

    // MARK: - Locating the CLI

    /// Find the `codex` binary. A menu-bar app launched from Finder inherits a bare
    /// `PATH`, so the usual install locations are probed directly before falling back
    /// to the user's login shell (which is what covers nvm/asdf/volta-style installs).
    /// Deliberately not cached: this runs only when a token has actually expired, and
    /// caching a miss would ignore a `codex` installed after launch.
    private static func executable() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".bun/bin/codex"),
        ]
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) { return hit }
        return loginShellLookup()
    }

    private static func loginShellLookup() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", "command -v codex"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        // Read before waiting: a login shell can emit more than fits the pipe buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
