import Foundation
import MQTTNIO
import NIOCore
import NIOPosix

/// Connects to the configured MQTT broker, subscribes to the configured
/// topic, and forwards the (string) payload of every message on that
/// topic via `onValue`. Handles reconnects with simple backoff.
final class MQTTService {
    var onValue: ((String) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    private var client: MQTTClient?
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var currentTopic: String = ""
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
        currentTopic = settings.mqttTopic

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
                guard publish.topicName == self.currentTopic else { return }
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
                newClient.subscribe(to: [MQTTSubscribeInfo(topicFilter: settings.mqttTopic, qos: .atLeastOnce)])
                    .whenFailure { error in NSLogError("MQTT subscribe failed: \(error)") }
            case .failure(let error):
                NSLogError("MQTT connect failed: \(error)")
                DispatchQueue.main.async { self.onConnectionStateChanged?(false) }
                self.scheduleReconnect(settings: settings, password: password)
            }
        }
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
