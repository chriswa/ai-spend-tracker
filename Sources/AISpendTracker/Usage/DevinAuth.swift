import Foundation

/// Locates the Devin/Windsurf session token this Mac already has, the same way the
/// Devin CLI and Devin Desktop authenticate — no Keychain, no login prompt.
///
/// Two sources, tried in order:
///   1. The Devin CLI's `~/.local/share/devin/credentials.toml`, a flat file of
///      top-level `key = "value"` pairs. `windsurf_api_key` is the token; `org_id`
///      is cached separately in `~/.config/devin/config.json`.
///   2. Devin Desktop's VS Code secret store `state.vscdb`, where the same token is
///      kept in plaintext under the `windsurfAuthStatus` item's `apiKey`.
///
/// The token is the Codeium/Windsurf session key: it authenticates the usage-meter
/// RPC on `server.codeium.com` (as request metadata) and the Devin webapp spend API
/// on `app.devin.ai` (as a bearer token).
enum DevinAuth {
    struct Session: Sendable {
        let token: String
        /// Org id from the CLI config, or empty when it must be resolved from the API.
        let orgID: String
    }

    /// Neither the CLI credentials file nor Devin Desktop's store held a token —
    /// Devin isn't signed in on this Mac.
    struct NotSignedInError: Error {}

    static func loadSession() throws -> Session {
        if let token = tokenFromCLICredentials() {
            return Session(token: token, orgID: cachedOrgID() ?? "")
        }
        if let token = tokenFromDesktopStore() {
            return Session(token: token, orgID: cachedOrgID() ?? "")
        }
        throw NotSignedInError()
    }

    // MARK: - CLI credentials.toml

    private static var cliCredentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devin/credentials.toml")
    }

    private static func tokenFromCLICredentials() -> String? {
        guard let toml = try? String(contentsOf: cliCredentialsURL, encoding: .utf8) else { return nil }
        return tomlValue(toml, key: "windsurf_api_key")
    }

    /// Reads one top-level `key = "value"` pair. Quotes are optional and there are no
    /// sections to scan past, so a line scan is the whole parser.
    private static func tomlValue(_ toml: String, key: String) -> String? {
        for line in toml.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    private static func cachedOrgID() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/devin/config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ConfigFile.self, from: data) else { return nil }
        let id = config.devin?.org_id
        return (id?.isEmpty == false) ? id : nil
    }

    private struct ConfigFile: Decodable {
        struct Devin: Decodable { let org_id: String? }
        let devin: Devin?
    }

    // MARK: - Devin Desktop state.vscdb

    private static var desktopStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
    }

    /// The token lives in a SQLite DB as JSON under the `windsurfAuthStatus` key. We
    /// have no SQLite dependency, so shell out to the system `sqlite3` (read-only via
    /// the `immutable` URI so an open Devin Desktop isn't disturbed) and pull the
    /// `apiKey` field out of the JSON value.
    private static func tokenFromDesktopStore() -> String? {
        let db = desktopStoreURL
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "file:\(db.path)?immutable=1",
            "SELECT json_extract(value,'$.apiKey') FROM ItemTable WHERE key='windsurfAuthStatus';",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return nil }
        let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
