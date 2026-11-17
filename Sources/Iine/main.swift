import AppKit
import IineCore

MainActor.assumeIsolated {
    let app = NSApplication.shared
    for notice in LegacyBrandMigration.run() {
        print("[migration] \(notice)")
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
