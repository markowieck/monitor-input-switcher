import SwiftUI

/// Fixed column widths used throughout the form so every row - text
/// fields, toggles, buttons, table columns - lines up exactly. SwiftUI's
/// `Grid` sizes each column from its cells' *ideal* size, which for a
/// `TextField` is effectively "as much as it can get"; mixed with rows of
/// different content that produced visibly inconsistent widths. Using the
/// same explicit width on every corresponding cell sidesteps that
/// entirely - there's no auto-sizing left to disagree.
private enum Layout {
    static let labelWidth: CGFloat = 90
    static let inputVCPWidth: CGFloat = 70
    static let deleteButtonWidth: CGFloat = 20
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    var onTestConnection: () -> Void
    var onManualRefreshInput: () -> Void

    var body: some View {
        Form {
            Section {
                FormRow("Server") {
                    TextField("", text: $store.settings.mqttHost, prompt: Text("mqtt.example.com"))
                }
                FormRow("Port") {
                    TextField("", value: $store.settings.mqttPort, formatter: NumberFormatter())
                }
                ToggleRow(label: "Use TLS", isOn: $store.settings.mqttUseTLS)
                FormRow("Username") {
                    TextField("", text: $store.settings.mqttUsername, prompt: Text("optional"))
                }
                FormRow("Password") {
                    SecureField("", text: $store.mqttPassword, prompt: Text("optional"))
                }
                FormRow("Topic") {
                    TextField("", text: $store.settings.mqttTopic, prompt: Text("home/monitor/input"))
                }
                FormRow("") {
                    HStack {
                        ConnectionStatusLabel(result: store.connectionTestResult)
                        Spacer()
                        Button("Test Connection") { onTestConnection() }
                    }
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
                ToggleRow(label: "Start at Login", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { newValue in
                        store.settings.launchAtLogin = newValue
                        LoginItemService.setEnabled(newValue)
                    }
                ))
                FormRow("Current Input") {
                    HStack {
                        Spacer()
                        Button("Refresh Now") { onManualRefreshInput() }
                    }
                }
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
    }
}

/// A single settings row: a fixed-width, trailing-aligned label followed
/// by content that fills the rest of the row's width. Every row - across
/// every section - uses the exact same `Layout.labelWidth`, so all the
/// label text lines up on one edge and all the fields/controls line up on
/// the other, independent of label text length or control type.
private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Layout.labelWidth, alignment: .trailing)
            content
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A toggle row that reserves the same `Layout.labelWidth` label column as
/// `FormRow`, so its label lines up with every other row's label - the
/// toggle itself sits at the trailing edge (matching how toggle rows look
/// in System Settings).
private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Layout.labelWidth, alignment: .trailing)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("MQTT Value")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("VCP Value")
                    .frame(width: Layout.inputVCPWidth, alignment: .leading)
                Spacer()
                    .frame(width: Layout.deleteButtonWidth)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach($inputs) { $input in
                HStack(spacing: 10) {
                    LeftAlignedTextField(text: $input.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LeftAlignedTextField(text: $input.mqttValue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LeftAlignedTextField(text: Binding(
                        get: { String(input.vcpValue) },
                        set: { input.vcpValue = Int($0.filter(\.isNumber)) ?? 0 }
                    ))
                        .frame(width: Layout.inputVCPWidth, alignment: .leading)
                    Button(role: .destructive) {
                        inputs.removeAll { $0.id == input.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: Layout.deleteButtonWidth)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// SwiftUI's `TextField` on macOS ignores `.multilineTextAlignment(.leading)`
/// when styled with `.roundedBorder` inside a `Form` - the underlying
/// `NSTextField` keeps rendering its content trailing-aligned regardless.
/// A plain `NSTextField` sidesteps that, but its native bezel draws a
/// visibly lighter fill than `.roundedBorder`'s outline-only look - so the
/// chrome (border/corner radius) is drawn here in SwiftUI to match the rest
/// of the form exactly, with the `NSTextField` underneath left completely
/// unstyled (no bezel, no fill) and used only for text input and alignment.
private struct LeftAlignedTextField: View {
    @Binding var text: String

    var body: some View {
        LeftAlignedTextFieldRepresentable(text: $text)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 5.5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

private struct LeftAlignedTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .left
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.alignment = .left
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
