// Read-only desktop focus/window observer around a background acceptance command.
import AppKit
import CoreGraphics
import Foundation
let command = Array(CommandLine.arguments.dropFirst())
guard !command.isEmpty else {
    fputs("Usage: observe-background-macos /absolute/command [args...]\n", stderr)
    exit(2)
}
let task = Process()
task.executableURL = URL(fileURLWithPath: command[0])
task.arguments = Array(command.dropFirst())
let workspace = NSWorkspace.shared
let start = workspace.frontmostApplication
var violations = Set<String>()
let observer = workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        let name = app.executableURL?.lastPathComponent ?? app.localizedName ?? "unknown"
        print("Activated: \(name) pid=\(app.processIdentifier)")
        if name.contains("vehicle-offscreen") || name.contains("incinerator_engine") { violations.insert("activation:\(name)") }
    }
}
let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for window in windows {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            if owner.contains("vehicle-offscreen") { violations.insert("visible-window:\(owner)") }
        }
    }
}
print("Frontmost before: \(start?.localizedName ?? "unknown") pid=\(start?.processIdentifier ?? 0)")
try task.run()
while task.isRunning { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
task.waitUntilExit()
timer.invalidate()
workspace.notificationCenter.removeObserver(observer)
let end = workspace.frontmostApplication
print("Frontmost after: \(end?.localizedName ?? "unknown") pid=\(end?.processIdentifier ?? 0)")
print("Background violations: \(violations.sorted()); command status: \(task.terminationStatus)")
exit(violations.isEmpty ? task.terminationStatus : 1)
