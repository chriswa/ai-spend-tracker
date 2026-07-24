import Foundation

/// Reads generic-password Keychain items by shelling out to `/usr/bin/security`.
/// This avoids Keychain-entitlement fuss: the login items we read (Claude Code and
/// Cursor credentials) have ACLs that trust `/usr/bin/security`, so no interactive
/// prompt appears. Shared by the providers that authenticate from the Keychain.
enum Keychain {
    /// The item doesn't exist (errSecItemNotFound) — either the tool isn't set up on
    /// this machine, or the item is momentarily absent while the tool rewrites it.
    struct ItemNotFound: Error {}
    /// A transient failure (locked keychain, denied prompt, …). `detail` is stderr.
    struct AccessError: Error { let detail: String }

    /// The item's secret value (`-w`), trimmed. Throws `ItemNotFound` when absent,
    /// `AccessError` for any other (retryable) failure.
    static func readGenericPassword(service: String, account: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            if task.terminationStatus == 44 { throw ItemNotFound() }   // errSecItemNotFound
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AccessError(detail: stderr.isEmpty ? "security exited \(task.terminationStatus)" : stderr)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw ItemNotFound() }
        return trimmed
    }
}
