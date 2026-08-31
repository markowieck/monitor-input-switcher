import AppKit
import Combine

/// Owns the NSStatusItem and its dropdown menu: lists the configured
/// inputs (checkmarking the one currently active on the monitor),
/// exposes MQTT connection state, and the Settings/Quit actions.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settingsStore: SettingsStore
    private let ddc: DDCController
    private var cancellables = Set<AnyCancellable>()

    // Reused across rebuilds so the delegate keeps receiving menuWillOpen
    // for the menu that's actually assigned to the status item.
    private let menu = NSMenu()
    private var refreshItem: NSMenuItem?
    private var spinnerWorkItem: DispatchWorkItem?

    private var mqttConnected = false
    private var currentVCPValue: Int?

    var onSelectInput: ((InputMapping) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onRefreshCurrentInput: (() -> Void)?

    init(settingsStore: SettingsStore, ddc: DDCController) {
        self.settingsStore = settingsStore
        self.ddc = ddc
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Monitor Input Switcher")
        }

        menu.delegate = self
        statusItem.menu = menu

        settingsStore.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        rebuildMenu()
    }

    func setMQTTConnected(_ connected: Bool) {
        mqttConnected = connected
        rebuildMenu()
    }

    func setCurrentVCPValue(_ value: Int?) {
        currentVCPValue = value
        stopSpinner()
        rebuildMenu()
    }

    /// Query the current input as soon as the menu is opened, so a stale
    /// checkmark (e.g. left over from switching inputs elsewhere) doesn't
    /// linger. If the DDC round-trip takes a moment, show a small spinner
    /// on the refresh item instead of the static icon.
    func menuWillOpen(_ menu: NSMenu) {
        let workItem = DispatchWorkItem { [weak self] in self?.startSpinner() }
        spinnerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        onRefreshCurrentInput?()
    }

    func menuDidClose(_ menu: NSMenu) {
        spinnerWorkItem?.cancel()
        spinnerWorkItem = nil
    }

    private func startSpinner() {
        guard let refreshItem else { return }
        refreshItem.isEnabled = false
        refreshItem.view = makeSpinnerView()
    }

    private func stopSpinner() {
        spinnerWorkItem?.cancel()
        spinnerWorkItem = nil
    }

    private func makeSpinnerView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))

        let spinner = NSProgressIndicator(frame: NSRect(x: 14, y: 3, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        container.addSubview(spinner)

        let label = NSTextField(labelWithString: "Refreshing…")
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 36, y: 2, width: 170, height: 18)
        container.addSubview(label)

        return container
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let statusLine = NSMenuItem(
            title: mqttConnected ? "MQTT: Connected" : "MQTT: Disconnected",
            action: nil, keyEquivalent: ""
        )
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let inputs = settingsStore.settings.inputs
        if inputs.isEmpty {
            let item = NSMenuItem(title: "No inputs configured", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for input in inputs {
                let item = NSMenuItem(title: input.name, action: #selector(selectInput(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = input
                item.state = (currentVCPValue == input.vcpValue) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Current Input", action: #selector(refreshCurrent), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refreshItem)
        self.refreshItem = refreshItem

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Monitor Input Switcher", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let input = sender.representedObject as? InputMapping else { return }
        onSelectInput?(input)
    }

    @objc private func refreshCurrent() {
        onRefreshCurrentInput?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
