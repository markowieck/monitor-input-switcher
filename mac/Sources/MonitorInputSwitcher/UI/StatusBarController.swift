import AppKit
import Combine

/// Owns the NSStatusItem and its dropdown menu: lists the configured
/// inputs (checkmarking the one currently active on the monitor),
/// exposes MQTT connection state, and the Settings/Quit actions.
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let settingsStore: SettingsStore
    private let ddc: DDCController
    private var cancellables = Set<AnyCancellable>()

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

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Monitor Input Switcher")
        }

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
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

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
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Monitor Input Switcher", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
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
