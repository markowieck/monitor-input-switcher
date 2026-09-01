import Foundation
import Combine

/// Loads/saves `Settings` as JSON under Application Support, and publishes
/// changes so the status bar / MQTT service can react.
final class SettingsStore: ObservableObject {
    @Published var settings: Settings {
        didSet { save() }
    }

    /// Kept in memory only; never written to the settings JSON file.
    @Published var mqttPassword: String {
        didSet { KeychainStore.savePassword(mqttPassword) }
    }

    /// Transient, UI-only status text shown next to "Test Connection".
    @Published var connectionTestResult: String?

    /// Transient, UI-only: whether the app's actual MQTT connection (not
    /// the one-off "Test Connection" probe) is currently up. Not
    /// persisted - AppDelegate keeps this in sync with `MQTTService`'s
    /// real connection state.
    @Published var mqttConnected = false

    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MonitorInputSwitcher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("settings.json")

        // Assigning through `self.settings`/`self.mqttPassword` here (even
        // in init) fires their `didSet`, which re-saves to disk/Keychain
        // immediately - for the Keychain write in particular, that means
        // SecItemDelete+SecItemAdd on every single launch, discarding
        // whatever ACL the Keychain prompt's "Always Allow" had just
        // granted and forcing it to re-prompt on the *next* launch. Init
        // is just restoring already-persisted state, not a real change,
        // so assign straight to the `@Published` backing storage instead
        // (`_settings`/`_mqttPassword`) to load without re-triggering a
        // save.
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            self._settings = Published(initialValue: decoded)
        } else {
            self._settings = Published(initialValue: .default)
        }
        self._mqttPassword = Published(initialValue: KeychainStore.loadPassword())
    }

    private func save() {
        guard let data = try? JSONEncoder.pretty.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
