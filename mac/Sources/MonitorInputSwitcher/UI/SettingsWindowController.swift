import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init(store: SettingsStore, onTestConnection: @escaping () -> Void, onManualRefreshInput: @escaping () -> Void) {
        let view = SettingsView(store: store, onTestConnection: onTestConnection, onManualRefreshInput: onManualRefreshInput)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Monitor Input Switcher Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
