import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    var onTestConnection: () -> Void
    var onManualRefreshInput: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    TextField("", text: $store.settings.mqttHost, prompt: Text("mqtt.example.com"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("", value: $store.settings.mqttPort, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Toggle("Use TLS", isOn: $store.settings.mqttUseTLS)
                LabeledContent("Username") {
                    TextField("", text: $store.settings.mqttUsername, prompt: Text("optional"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Password") {
                    SecureField("", text: $store.mqttPassword, prompt: Text("optional"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Topic") {
                    TextField("", text: $store.settings.mqttTopic, prompt: Text("home/monitor/input"))
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    ConnectionStatusLabel(result: store.connectionTestResult)
                    Spacer()
                    Button("Test Connection") { onTestConnection() }
                }
            } header: {
                Text("MQTT Broker")
            }

            Section {
                InputMappingRows(inputs: $store.settings.inputs)

                Button {
                    store.settings.inputs.append(InputMapping(name: "New Input", mqttValue: "", vcpValue: 0))
                } label: {
                    Label("Add Input", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Inputs")
            } footer: {
                Text("Map incoming MQTT payload values to a DDC/CI input-source (VCP 0x60) value. These also appear in the menu bar dropdown, with the monitor's current input highlighted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start at Login", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { newValue in
                        store.settings.launchAtLogin = newValue
                        LoginItemService.setEnabled(newValue)
                    }
                ))

                LabeledContent("Current Input") {
                    Button("Refresh Now") { onManualRefreshInput() }
                }
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
    }
}

private struct ConnectionStatusLabel: View {
    let result: String?

    var body: some View {
        if let result {
            Label(result, systemImage: icon)
                .font(.callout)
                .foregroundStyle(color)
                .transition(.opacity)
        }
    }

    private var icon: String {
        if result == "Connected ✓" { return "checkmark.circle.fill" }
        if result == "Connecting…" { return "ellipsis.circle" }
        return "xmark.circle.fill"
    }

    private var color: Color {
        if result == "Connected ✓" { return .green }
        if result == "Connecting…" { return .secondary }
        return .red
    }
}

private struct InputMappingRows: View {
    @Binding var inputs: [InputMapping]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Name").gridColumnHeader
                Text("MQTT Value").gridColumnHeader
                Text("VCP Value").gridColumnHeader
                Color.clear.frame(width: 20)
            }

            ForEach($inputs) { $input in
                GridRow {
                    TextField("", text: $input.name)
                        .textFieldStyle(.roundedBorder)
                    TextField("", text: $input.mqttValue)
                        .textFieldStyle(.roundedBorder)
                    TextField("", value: $input.vcpValue, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 90)
                    Button(role: .destructive) {
                        inputs.removeAll { $0.id == input.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private extension Text {
    var gridColumnHeader: some View {
        self.font(.caption)
            .foregroundStyle(.secondary)
    }
}
