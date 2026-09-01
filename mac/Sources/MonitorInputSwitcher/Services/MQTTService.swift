import Foundation
import MQTTNIO
import NIOCore
import NIOPosix

/// Connects to the configured MQTT broker. Subscribes to a set of
/// per-monitor command topics and forwards `(commandTopic, value)` of
/// every message received on one of them via `onValue`; publishes
/// retained state and Home Assistant Discovery configs to explicit
/// topics via `publish`/`publishDiscovery`. Handles reconnects with
/// simple backoff.
final class MQTTService {
    var onValue: ((_ commandTopic: String, _ value: String) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    private var client: MQTTClient?
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var subscribedCommandTopics: Set<String> = []
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 2
    private var shouldStayConnected = false

    func start(settings: Settings, password: String, commandTopics: [String] = []) {
        stop()
        shouldStayConnected = true
        reconnectDelay = 2
        subscribedCommandTopics = Set(commandTopics)
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
                guard self.subscribedCommandTopics.contains(publish.topicName) else { return }
                var buffer = publish.payload
                let value = buffer.readString(length: buffer.readableBytes) ?? ""
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let topic = publish.topicName
                DispatchQueue.main.async {
                    self.onValue?(topic, trimmed)
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
                if !self.subscribedCommandTopics.isEmpty {
                    let subscriptions = self.subscribedCommandTopics.map { MQTTSubscribeInfo(topicFilter: $0, qos: .atLeastOnce) }
                    newClient.subscribe(to: subscriptions)
                        .whenFailure { error in NSLogError("MQTT subscribe failed: \(error)") }
                }
            case .failure(let error):
                NSLogError("MQTT connect failed: \(error)")
                DispatchQueue.main.async { self.onConnectionStateChanged?(false) }
                self.scheduleReconnect(settings: settings, password: password)
            }
        }
    }

    /// Publishes the given value (retained) to an explicit state topic,
    /// so other MQTT clients (e.g. Home Assistant) see a monitor's
    /// current input even when it was changed locally - from the menu,
    /// or detected on a poll.
    func publish(topic: String, value: String) {
        publish(topic: topic, payload: ByteBuffer(string: value), retain: true)
    }

    /// Publishes a Home Assistant MQTT Discovery config for a `select`
    /// entity wired to the given state/command topics, so the input
    /// shows up in Home Assistant automatically - no manual YAML needed
    /// on the HA side. Retained, so HA (or its MQTT broker) picks it up
    /// whenever it (re)connects, not just at publish time.
    func publishDiscovery(
        uniqueId: String,
        name: String,
        deviceName: String,
        appVersion: String,
        stateTopic: String,
        commandTopic: String,
        options: [String]
    ) {
        guard !options.isEmpty else { return }
        let configPayload: [String: Any] = [
            "name": name,
            "unique_id": uniqueId,
            "object_id": uniqueId,
            "state_topic": stateTopic,
            "command_topic": commandTopic,
            "options": options,
            "device": [
                "identifiers": [uniqueId],
                "name": deviceName,
                "manufacturer": "Monitor Input Switcher",
                "model": "v\(appVersion)"
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
