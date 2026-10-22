import Foundation

/// Append-only per-provider log of usage samples (each window's utilization plus
/// month-to-date spend — one row per fetch). One instance and one file per provider
/// (`history-<id>.jsonl`), so providers never contend for the same log. Kept for
/// ~30 days for short-range sparklines now and longer trends later; the sparkline
/// display window is decoupled from this retention.
///
/// Stored as JSONL (one JSON object per line) so each fetch is an O(1) append rather
/// than a full-file rewrite. The file is compacted (pruned + rewritten) on launch
/// and thereafter only once it drifts a day past retention.
@MainActor
final class UsageHistory {
    /// A single point in time. `windows` maps a window caption ("5-Hour", "Weekly",
    /// "Monthly", …) to its utilization %; `spendCents` is month-to-date dollars×100.
    /// Both are optional-friendly (a partial fetch still records what it had).
    /// `account` is the reading's `AccountRef.id`, nil for providers without accounts.
    struct Sample: Codable, Equatable {
        var date: Date
        var windows: [String: Double]
        var spendCents: Double?
        var account: String?

        init(date: Date, windows: [String: Double] = [:], spendCents: Double? = nil,
             account: String? = nil) {
            self.date = date
            self.windows = windows
            self.spendCents = spendCents
            self.account = account
        }
    }

    /// Default sparkline display window (independent of on-disk retention).
    static let sparklineWindow: TimeInterval = 2 * 60 * 60

    let retention: TimeInterval
    private let compactionSlack: TimeInterval = 24 * 60 * 60

    private(set) var samples: [Sample] = []
    private let fileURL: URL

    /// Production: one file per provider under Application Support.
    convenience init(providerID: ProviderID, retention: TimeInterval = 30 * 24 * 60 * 60) {
        let url = AppPaths.applicationSupport.appendingPathComponent("history-\(providerID.rawValue).jsonl")
        self.init(fileURL: url, retention: retention)
    }

    /// Test-friendly: explicit file.
    init(fileURL: URL, retention: TimeInterval = 30 * 24 * 60 * 60) {
        self.fileURL = fileURL
        self.retention = retention
        load()
    }

    /// Record a fetch's snapshot. Uses `now` (injectable for tests) as the sample time.
    func record(_ snapshot: ProviderSnapshot, now: Date = Date()) {
        var windows: [String: Double] = [:]
        for w in snapshot.windows { windows[w.caption] = w.utilization }
        let sample = Sample(date: now, windows: windows, spendCents: snapshot.spend?.usedCents,
                            account: snapshot.account?.id)
        samples.append(sample)
        append(sample)
        if let oldest = samples.first, now.timeIntervalSince(oldest.date) > retention + compactionSlack {
            prune(now: now)
            rewrite()
        }
    }

    /// Samples within `window` of `now`, oldest first.
    func recent(window: TimeInterval = UsageHistory.sparklineWindow, now: Date = Date()) -> [Sample] {
        samples.filter { now.timeIntervalSince($0.date) <= window }
    }

    // MARK: - Persistence

    private func prune(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.date) > retention }
    }

    private func load() {
        if let raw = try? String(contentsOf: fileURL, encoding: .utf8), !raw.isEmpty {
            samples = Self.decodeJSONL(raw)
        }
        prune(now: Date())
        rewrite()   // compact on launch
    }

    private static func decodeJSONL(_ raw: String) -> [Sample] {
        let decoder = JSONDecoder()
        return raw.split(separator: "\n").compactMap { line in
            try? decoder.decode(Sample.self, from: Data(line.utf8))
        }
    }

    private func append(_ sample: Sample) {
        guard var line = try? JSONEncoder().encode(sample) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try? line.write(to: fileURL, options: .atomic)
        }
    }

    private func rewrite() {
        let encoder = JSONEncoder()
        let body = samples.compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        let out = body.isEmpty ? "" : body + "\n"
        try? out.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
