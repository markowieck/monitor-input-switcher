import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    var onTestConnection: () -> Void
    var onManualRefreshInput: () -> Void

    var body: some View {
        Form {
            Section("MQTT Broker") {
                TextField("Server", text: $store.settings.mqttHost)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", value: $store.settings.mqttPort, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                Toggle("Use TLS", isOn: $store.settings.mqttUseTLS)
                TextField("Username (optional)", text: $store.settings.mqttUsername)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password (optional)", text: $store.mqttPassword)
                    .textFieldStyle(.roundedBorder)
                TextField("Topic", text: $store.settings.mqttTopic)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Test Connection") { onTestConnection() }
                    if let result = store.connectionTestResult {
                        Text(result).foregroundStyle(.secondary).font(.caption)
                    }
                }
            }

            Section("Inputs") {
                Text("Map incoming MQTT payload values to a DDC/CI input-source (VCP 0x60) value. These also show up in the menu bar dropdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                InputMappingTable(inputs: $store.settings.inputs)
            }

            Section("General") {
                Toggle("Start at Login", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { newValue in
                        store.settings.launchAtLogin = newValue
                        LoginItemService.setEnabled(newValue)
                    }
                ))

                Button("Refresh Current Input Now") { onManualRefreshInput() }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct InputMappingTable: View {
    @Binding var inputs: [InputMapping]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($inputs) { $input in
                HStack {
                    TextField("Name", text: $input.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    TextField("MQTT value", text: $input.mqttValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    TextField("VCP value", value: $input.vcpValue, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Button(role: .destructive) {
                        inputs.removeAll { $0.id == input.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }

            Button {
                inputs.append(InputMapping(name: "New Input", mqttValue: "", vcpValue: 0))
            } label: {
                Label("Add Input", systemImage: "plus")
            }
        }
    }
}
