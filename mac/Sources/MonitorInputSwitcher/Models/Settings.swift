import Foundation

/// Persisted app settings. The MQTT password is intentionally NOT stored
/// here - it lives in the Keychain (see KeychainStore) and is merged in
/// at load time / stripped out at save time.
struct Settings: Codable, Equatable {
    var mqttHost: String
    var mqttPort: Int
    var mqttUseTLS: Bool
    var mqttUsername: String
    /// Base MQTT topic. State is published here (retained); commands are
    /// read from "<mqttTopic>/set" - the Home Assistant convention.
    var mqttTopic: String
    var clientIdSuffix: String
    var launchAtLogin: Bool
    var inputs: [InputMapping]

    static let `default` = Settings(
        mqttHost: "",
        mqttPort: 1883,
        mqttUseTLS: false,
        mqttUsername: "",
        mqttTopic: "home/monitor/input",
        clientIdSuffix: UUID().uuidString.prefix(8).description,
        launchAtLogin: false,
        inputs: [
            InputMapping(name: "HDMI", mqttValue: "hdmi", vcpValue: 17),
            InputMapping(name: "DisplayPort", mqttValue: "dp", vcpValue: 15),
            InputMapping(name: "USB-C", mqttValue: "usbc", vcpValue: 27)
        ]
    )
}
