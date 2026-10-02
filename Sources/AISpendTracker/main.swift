import AppKit

// Dev-only: render a grid of pie scenarios to a PNG and exit (no menu bar).
if let i = CommandLine.arguments.firstIndex(of: "--render"),
   let path = CommandLine.arguments.dropFirst(i + 1).first {
    DebugRender.run(outPath: path)
    exit(0)
}

// Print the current readings as JSON and exit (no menu bar). See `UsageReport`.
if CommandLine.arguments.contains("--json") {
    UsageReport.run()
    exit(0)
}

// Runs as a menu-bar accessory: no dock icon, no main window. (Equivalent to
// LSUIElement, set programmatically so `swift run` works without the bundle.)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let coordinator = AppCoordinator()
app.delegate = coordinator

app.run()
