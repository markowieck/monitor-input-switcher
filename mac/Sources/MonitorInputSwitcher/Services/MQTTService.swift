import Foundation
import MQTTNIO
import NIOCore
import NIOPosix

/// Connects to the configured MQTT broker, subscribes to the command
/// topic (`<topic>/set`) and forwards the (string) payload of every
/// message on it via `onValue`, and publishes the current input to the
/// state topic (`<topic>`, retained) via `publish(_:)`. This follows the
/// Home Assistant MQTT convention (base topic = state, `/set` = command).
/// Handles reconnects with simple backoff.
final class MQTTService {
    var onValue: ((String) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    private var client: MQTTClient?
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var currentStateTopic: String = ""
    private var currentCommandTopic: String = ""
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 2
    private var shouldStayConnected = false

    func start(settings: Settings, password: String) {
        stop()
        shouldStayConnected = true
        reconnectDelay = 2
        connect(settings: settings, password: password)
    }

    func stop() {
        shouldStayConnected = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        if let client {
            try? client.syncShutdownGracefully()
        }
        client = nil
    }

    private func connect(settings: Settings, password: String) {
        guard !settings.mqttHost.isEmpty else { return }
        currentStateTopic = settings.mqttTopic
        currentCommandTopic = settings.mqttTopic + "/set"

        // MQTTClient requires an explicit shutdown before it's deallocated
        // (it traps in deinit otherwise) - never just overwrite `client`.
        if let previous = client {
            client = nil
            try? previous.syncShutdownGracefully()
        }

        let clientId = "monitor-input-switcher-\(settings.clientIdSuffix)"
        let newClient = MQTTClient(
            host: settings.mqttHost,
            port: settings.mqttPort,
            identifier: clientId,
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: .init(
                userName: settings.mqttUsername.isEmpty ? nil : settings.mqttUsername,
                password: password.isEmpty ? nil : password,
                useSSL: settings.mqttUseTLS
            )
        )
        client = newClient

        newClient.addPublishListener(named: "MonitorInputSwitcher") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let publish):
                guard publish.topicName == self.currentCommandTopic else { return }
                var buffer = publish.payload
                let value = buffer.readString(length: buffer.readableBytes) ?? ""
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.onValue?(trimmed)
                }
            case .failure(let error):
                NSLogError("MQTT publish listener error: \(error)")
            }
        }

        newClient.connect().whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                NSLogInfo("MQTT connected to \(settings.mqttHost):\(settings.mqttPort)")
                self.reconnectDelay = 2
                DispatchQueue.main.async { self.onConnectionStateChanged?(true) }
                newClient.subscribe(to: [MQTTSubscribeInfo(topicFilter: self.currentCommandTopic, qos: .atLeastOnce)])
                    .whenFailure { error in NSLogError("MQTT subscribe failed: \(error)") }
            case .failure(let error):
                NSLogError("MQTT connect failed: \(error)")
                DispatchQueue.main.async { self.onConnectionStateChanged?(false) }
                self.scheduleReconnect(settings: settings, password: password)
            }
        }
    }

    /// Publishes the given value (retained) to the state topic, so other
    /// MQTT clients (e.g. Home Assistant) see the current input even when
    /// it was changed locally - from the menu, or detected on a poll.
    func publish(_ value: String) {
        guard !currentStateTopic.isEmpty else { return }
        publish(topic: currentStateTopic, payload: ByteBuffer(string: value), retain: true)
    }

    /// Publishes a Home Assistant MQTT Discovery config for a `select`
    /// entity wired to this instance's state/command topics, so the
    /// input shows up in Home Assistant automatically - no manual YAML
    /// needed on the HA side. Retained, so HA (or its MQTT broker)
    /// picks it up whenever it (re)connects, not just at publish time.
    func publishDiscovery(uniqueId: String, name: String, deviceName: String, options: [String]) {
        guard !currentStateTopic.isEmpty, !currentCommandTopic.isEmpty, !options.isEmpty else { return }
        let configPayload: [String: Any] = [
            "name": name,
            "unique_id": uniqueId,
            "object_id": uniqueId,
            "state_topic": currentStateTopic,
            "command_topic": currentCommandTopic,
            "options": options,
            "device": [
                "identifiers": [uniqueId],
                "name": deviceName,
                "manufacturer": "Monitor Input Switcher"
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: configPayload) else {
            NSLogError("MQTT discovery: failed to encode config JSON")
            return
        }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        publish(topic: "homeassistant/select/\(uniqueId)/config", payload: buffer, retain: true)
    }

    private func publish(topic: String, payload: ByteBuffer, retain: Bool) {
        guard let client else { return }
        client.publish(to: topic, payload: payload, qos: .atLeastOnce, retain: retain)
            .whenFailure { error in NSLogError("MQTT publish to \(topic) failed: \(error)") }
    }

    private func scheduleReconnect(settings: Settings, password: String) {
        guard shouldStayConnected else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shouldStayConnected else { return }
            self.connect(settings: settings, password: password)
        }
        reconnectWorkItem = workItem
        reconnectDelay = min(reconnectDelay * 1.5, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: workItem)
    }

    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }
}
