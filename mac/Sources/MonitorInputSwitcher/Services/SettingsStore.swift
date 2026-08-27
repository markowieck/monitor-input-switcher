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

    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MonitorInputSwitcher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
        self.mqttPassword = KeychainStore.loadPassword()
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
