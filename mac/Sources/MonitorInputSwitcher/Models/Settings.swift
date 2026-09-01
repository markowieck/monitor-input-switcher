import Foundation

/// Persisted app settings. The MQTT password is intentionally NOT stored
/// here - it lives in the Keychain (see KeychainStore) and is merged in
/// at load time / stripped out at save time.
struct Settings: Codable, Equatable {
    /// Whether the app connects to an MQTT broker at all. Off by default
    /// for someone who only wants menu-bar/DDC switching and doesn't want
    /// the app touching the network or the Keychain-stored password.
    var mqttEnabled: Bool
    var mqttHost: String
    var mqttPort: Int
    var mqttUseTLS: Bool
    var mqttUsername: String
    /// Base MQTT topic. With exactly one monitor, state is published here
    /// (retained) and commands are read from "<mqttTopic>/set" - the Home
    /// Assistant convention. With more than one monitor, each monitor
    /// gets its own "<mqttTopic>/<id>" / "<mqttTopic>/<id>/set" pair
    /// instead (see AppDelegate.topics(for:)), so this stays the exact
    /// topic already in use by existing single-monitor setups.
    var mqttTopic: String
    var clientIdSuffix: String
    var launchAtLogin: Bool
    var monitors: [MonitorConfig]

    static let `default` = Settings(
        mqttEnabled: true,
        mqttHost: "",
        mqttPort: 1883,
        mqttUseTLS: false,
        mqttUsername: "",
        mqttTopic: "home/monitor/input",
        clientIdSuffix: UUID().uuidString.prefix(8).description,
        launchAtLogin: false,
        monitors: [MonitorConfig(name: "Monitor", inputs: defaultInputTemplate())]
    )

    /// Starting-point input mappings for a monitor that has none yet (the
    /// very first monitor on a fresh install, or a newly detected one).
    /// VCP values here match this app's originally-supported monitor;
    /// other models can (and often do) use different values for the same
    /// physical port, so this is a template to verify/adjust, not a
    /// universal mapping - see the Inputs section footer in Settings.
    static func defaultInputTemplate() -> [InputMapping] {
        [
            InputMapping(name: "HDMI", mqttValue: "hdmi", vcpValue: 17),
            InputMapping(name: "DisplayPort", mqttValue: "dp", vcpValue: 15),
            InputMapping(name: "USB-C", mqttValue: "usbc", vcpValue: 27)
        ]
    }

    init(mqttEnabled: Bool, mqttHost: String, mqttPort: Int, mqttUseTLS: Bool, mqttUsername: String, mqttTopic: String, clientIdSuffix: String, launchAtLogin: Bool, monitors: [MonitorConfig]) {
        self.mqttEnabled = mqttEnabled
        self.mqttHost = mqttHost
        self.mqttPort = mqttPort
        self.mqttUseTLS = mqttUseTLS
        self.mqttUsername = mqttUsername
        self.mqttTopic = mqttTopic
        self.clientIdSuffix = clientIdSuffix
        self.launchAtLogin = launchAtLogin
        self.monitors = monitors
    }

    private enum CodingKeys: String, CodingKey {
        case mqttEnabled, mqttHost, mqttPort, mqttUseTLS, mqttUsername, mqttTopic, clientIdSuffix, launchAtLogin, monitors
        case legacyInputs = "inputs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Settings.json written before the MQTT toggle existed: default to
        // enabled, since that was the only behavior back then and existing
        // setups (like the one this shipped against) rely on it staying on.
        mqttEnabled = try c.decodeIfPresent(Bool.self, forKey: .mqttEnabled) ?? true
        mqttHost = try c.decode(String.self, forKey: .mqttHost)
        mqttPort = try c.decode(Int.self, forKey: .mqttPort)
        mqttUseTLS = try c.decode(Bool.self, forKey: .mqttUseTLS)
        mqttUsername = try c.decode(String.self, forKey: .mqttUsername)
        mqttTopic = try c.decode(String.self, forKey: .mqttTopic)
        clientIdSuffix = try c.decode(String.self, forKey: .clientIdSuffix)
        launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin)

        if let monitors = try c.decodeIfPresent([MonitorConfig].self, forKey: .monitors) {
            self.monitors = monitors
        } else {
            // Settings.json written before multi-monitor support: wrap the
            // old flat `inputs` list into a single unassigned MonitorConfig,
            // which the first detected monitor then claims and renames.
            let legacyInputs = try c.decodeIfPresent([InputMapping].self, forKey: .legacyInputs) ?? []
            self.monitors = [MonitorConfig(name: "Monitor", inputs: legacyInputs)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mqttEnabled, forKey: .mqttEnabled)
        try c.encode(mqttHost, forKey: .mqttHost)
        try c.encode(mqttPort, forKey: .mqttPort)
        try c.encode(mqttUseTLS, forKey: .mqttUseTLS)
        try c.encode(mqttUsername, forKey: .mqttUsername)
        try c.encode(mqttTopic, forKey: .mqttTopic)
        try c.encode(clientIdSuffix, forKey: .clientIdSuffix)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(monitors, forKey: .monitors)
    }
}
