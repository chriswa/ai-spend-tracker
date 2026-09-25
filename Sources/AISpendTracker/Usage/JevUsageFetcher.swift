import Foundation

/// Month-to-date spend for Jev (TypeSafe System One), read by running `jev --mtd`,
/// which prints the local-calendar-month total in USD (e.g. `12.345`). Jev is billed
/// purely per input token with no subscription, so there are no usage windows — the
/// reading only feeds the combined spend total.
///
/// `jev --mtd` sums a local usage log on every call. When that gets slow the snapshot
/// carries a warning (the data is still used), prompting the log's aggregation to be
/// optimized; a run past `timeout` is killed and counts as a failed fetch.
///
/// The figure is computed on this machine's clock, so it is exactly the local calendar
/// month and the ledger takes it verbatim (`SpendInfo.isLocalCalendarMonth`).
final class JevUsageFetcher: UsageProvider, @unchecked Sendable {
    let id: ProviderID = .jev
    let displayName = "Jev"
    let suggestedInterval: TimeInterval = 5 * 60

    /// A successful run slower than this adds a warning to the snapshot.
    static let slowThreshold: Duration = .seconds(2)
    /// A run slower than this is killed and fails the fetch.
    static let timeout: Duration = .seconds(30)

    /// One completed `jev --mtd` run.
    struct Run: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
        let duration: Duration
    }

    /// No `jev` on the login-shell `PATH`.
    struct CLINotFound: Error {}
    /// The command ran past `timeout` and was killed.
    struct TimedOut: Error {}
    /// The command exited non-zero.
    struct CommandFailed: Error, RawResponseCarrying {
        let run: Run
        var rawResponse: String { "exit \(run.status)\n\(run.stderr)\(run.stdout)" }
    }
    /// stdout wasn't a non-negative dollar amount.
    struct UnparseableOutput: Error {}

    typealias Runner = @Sendable () throws -> Run
    private let runner: Runner
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    init(runner: Runner? = nil, now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current) {
        self.runner = runner ?? { try JevUsageFetcher.runCommand() }
        self.now = now
        self.calendar = calendar
    }

    func fetch() async throws -> FetchResult {
        try await Task.detached(priority: .utility) { [self] in try fetchBlocking() }.value
    }

    /// Run the command and build the snapshot. A run that straddles local midnight at a
    /// month boundary is ambiguous (it may have summed either month), so it is repeated.
    func fetchBlocking() throws -> FetchResult {
        var started = now()
        var run = try runner()
        if !calendar.isDate(started, equalTo: now(), toGranularity: .month) {
            started = now()
            run = try runner()
        }
        let snapshot = try Self.snapshot(from: run, startedAt: started, calendar: calendar)
        return FetchResult(snapshot: snapshot, raw: run.stdout)
    }

    /// Map one run to a snapshot: the dollar figure as local-calendar-month spend, plus
    /// a slow-command warning when warranted. `startedAt` fixes which month it covers.
    static func snapshot(from run: Run, startedAt: Date, calendar: Calendar = .current) throws -> ProviderSnapshot {
        guard run.status == 0 else { throw CommandFailed(run: run) }
        let text = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dollars = Double(text), dollars.isFinite, dollars >= 0 else {
            throw ResponseParseError(rawResponse: run.stdout, underlying: UnparseableOutput())
        }
        let month = calendar.dateInterval(of: .month, for: startedAt)
        let spend = SpendInfo(usedCents: dollars * 100, apiLimitCents: nil, label: "Jev",
                              cycleResetsAt: month?.end, isLocalCalendarMonth: true)
        let warning = run.duration > slowThreshold
            ? "jev --mtd took \(formatSeconds(run.duration)) (over \(formatSeconds(slowThreshold))) — optimize its aggregation"
            : nil
        return ProviderSnapshot(windows: [], spend: spend, warning: warning)
    }

    func classify(_ error: Error) -> String {
        switch error {
        case let e as ResponseParseError:
            return classify(e.underlying)
        case is CLINotFound:
            return "jev not found on your login-shell PATH"
        case is TimedOut:
            return "jev --mtd didn't finish within \(Self.formatSeconds(Self.timeout))"
        case let e as CommandFailed:
            return "jev --mtd exited with status \(e.run.status)"
        case is UnparseableOutput:
            return "Couldn't parse jev --mtd output"
        default:
            return "jev --mtd failed: \(error.localizedDescription)"
        }
    }

    private static func formatSeconds(_ d: Duration) -> String {
        String(format: "%.1fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    // MARK: - Running the command

    /// Run `jev --mtd` under the login-shell `PATH` (its `#!/usr/bin/env bun` shebang
    /// needs it too), killing it at `timeout`.
    private static func runCommand() throws -> Run {
        guard let exe = LoginShell.which("jev") else { throw CLINotFound() }
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["--mtd"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginShell.path()
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        // Drain both pipes concurrently so a chatty command can't fill a buffer and wedge.
        let stdout = PipeReader(out), stderr = PipeReader(err)

        let clock = ContinuousClock()
        let start = clock.now
        try proc.run()
        let seconds = Double(timeout.components.seconds)
        guard exited.wait(timeout: .now() + seconds) == .success else {
            proc.terminate()
            throw TimedOut()
        }
        let duration = clock.now - start
        return Run(stdout: stdout.text(), stderr: stderr.text(),
                   status: proc.terminationStatus, duration: duration)
    }

    /// Reads a pipe to EOF on a background queue.
    private final class PipeReader: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()

        init(_ pipe: Pipe) {
            let handle = pipe.fileHandleForReading
            DispatchQueue.global().async { [self] in
                data = handle.readDataToEndOfFile()
                done.signal()
            }
        }

        /// The pipe's contents. Waits briefly for EOF, which follows the process exit.
        func text() -> String {
            guard done.wait(timeout: .now() + 2) == .success else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
