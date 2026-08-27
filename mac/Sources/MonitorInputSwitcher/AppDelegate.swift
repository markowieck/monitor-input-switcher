import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let ddc = DDCController()
    private let mqtt = MQTTService()

    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        ddc.refreshTransport()

        statusBar = StatusBarController(settingsStore: settingsStore, ddc: ddc)
        statusBar?.onSelectInput = { [weak self] input in self?.applyInput(input) }
        statusBar?.onOpenSettings = { [weak self] in self?.showSettings() }
        statusBar?.onQuit = { NSApp.terminate(nil) }
        statusBar?.onRefreshCurrentInput = { [weak self] in self?.refreshCurrentInput() }

        mqtt.onValue = { [weak self] value in self?.handleMQTTValue(value) }
        mqtt.onConnectionStateChanged = { [weak self] connected in self?.statusBar?.setMQTTConnected(connected) }

        settingsStore.$settings
            .removeDuplicates { old, new in
                old.mqttHost == new.mqttHost &&
                old.mqttPort == new.mqttPort &&
                old.mqttUseTLS == new.mqttUseTLS &&
                old.mqttUsername == new.mqttUsername &&
                old.mqttTopic == new.mqttTopic
            }
            .sink { [weak self] settings in
                guard let self else { return }
                self.mqtt.start(settings: settings, password: self.settingsStore.mqttPassword)
            }
            .store(in: &cancellables)

        LoginItemService.setEnabled(settingsStore.settings.launchAtLogin)

        refreshCurrentInput()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshCurrentInput()
        }
    }

    private func applyInput(_ input: InputMapping) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ok = self.ddc.setInput(vcpValue: input.vcpValue)
            DispatchQueue.main.async {
                if ok {
                    NSLogInfo("Switched input to \(input.name) (VCP \(input.vcpValue))")
                    self.statusBar?.setCurrentVCPValue(input.vcpValue)
                } else {
                    NSLogError("Failed to switch input to \(input.name)")
                }
            }
        }
    }

    private func handleMQTTValue(_ value: String) {
        guard let input = settingsStore.settings.inputs.first(where: {
            $0.mqttValue.caseInsensitiveCompare(value) == .orderedSame
        }) else {
            NSLogError("Received MQTT value \"\(value)\" with no matching input mapping")
            return
        }
        applyInput(input)
    }

    private func refreshCurrentInput() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let value = self.ddc.getCurrentInput()
            DispatchQueue.main.async {
                self.statusBar?.setCurrentVCPValue(value)
            }
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                store: settingsStore,
                onTestConnection: { [weak self] in self?.testMQTTConnection() },
                onManualRefreshInput: { [weak self] in self?.refreshCurrentInput() }
            )
        }
        settingsWindow?.show()
    }

    private func testMQTTConnection() {
        settingsStore.connectionTestResult = "Connecting…"
        let probe = MQTTService()
        probe.onConnectionStateChanged = { [weak self, weak probe] connected in
            self?.settingsStore.connectionTestResult = connected ? "Connected ✓" : "Connection failed"
            if connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    probe?.stop()
                }
            }
        }
        probe.start(settings: settingsStore.settings, password: settingsStore.mqttPassword)
    }
}
