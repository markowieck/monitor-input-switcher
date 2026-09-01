import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init(store: SettingsStore, onTestConnection: @escaping () -> Void, onManualRefreshInput: @escaping () -> Void) {
        let view = SettingsView(store: store, onTestConnection: onTestConnection, onManualRefreshInput: onManualRefreshInput)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Monitor Input Switcher Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // No separate title bar strip: traffic lights float over the
        // sidebar's own background and the content extends up behind
        // them, matching the look of BetterDisplay/System Settings-style
        // utility windows. SettingsView reserves top padding above the
        // sidebar list so its first row doesn't sit under the buttons.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 620, height: 420)
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
