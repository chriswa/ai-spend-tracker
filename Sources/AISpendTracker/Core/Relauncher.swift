import AppKit

/// Restarts the app: spawns a small detached `/bin/sh` helper that waits for our
/// PID to exit, then relaunches the bundle and exits itself. The helper survives
/// our death, so the relaunch happens after we're fully gone.
enum Relauncher {
    static func restartAfterTermination() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = ApplicationsRelocator.relaunchBundleURL
        // Relaunch the .app via LaunchServices when bundled; otherwise re-exec the
        // bare binary (dev `swift run`).
        let relaunch = bundle.pathExtension == "app"
            ? "open \(shellQuote(bundle.path))"
            : "\(shellQuote(Bundle.main.executablePath ?? bundle.path)) &"

        let script = """
        for _ in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        \(relaunch)
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
            Log.log("restart: relauncher spawned (waiting on pid \(pid)); terminating")
        } catch {
            Log.log("restart: failed to spawn relauncher: \(error)")
            return   // don't terminate if we couldn't arrange the relaunch
        }
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
