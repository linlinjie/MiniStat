import AppKit

if CommandLine.arguments.contains("--quota-check") {
    for name in ["Codex", "Cursor"] {
        do {
            let value = try name == "Codex" ? CodexQuotaProvider.read() : CursorQuotaProvider().read()
            print("\(name): \(value.text) remaining; windows=\(value.windows.count)")
            for window in value.currentWindows() {
                print("  \(window.title): \(Int(window.remaining.rounded()))% remaining")
            }
        } catch { print("\(name): \(error.localizedDescription)") }
    }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        controller = AppController()
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
