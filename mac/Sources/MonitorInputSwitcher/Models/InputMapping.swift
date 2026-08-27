import Foundation

/// Maps an incoming MQTT payload value (e.g. "hdmi") to a DDC/CI VCP
/// input-source value (e.g. 17) that gets written to VCP feature 0x60.
struct InputMapping: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var mqttValue: String
    var vcpValue: Int

    init(id: UUID = UUID(), name: String, mqttValue: String, vcpValue: Int) {
        self.id = id
        self.name = name
        self.mqttValue = mqttValue
        self.vcpValue = vcpValue
    }
}
