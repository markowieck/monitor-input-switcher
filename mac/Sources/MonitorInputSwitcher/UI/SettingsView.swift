import SwiftUI

/// Fixed column widths used throughout the detail forms so every row -
/// text fields, toggles, buttons, table columns - lines up exactly.
/// SwiftUI's `Grid` sizes each column from its cells' *ideal* size, which
/// for a `TextField` is effectively "as much as it can get"; mixed with
/// rows of different content that produced visibly inconsistent widths.
/// Using the same explicit width on every corresponding cell sidesteps
/// that entirely - there's no auto-sizing left to disagree.
private enum Layout {
    static let labelWidth: CGFloat = 90
    static let inputVCPWidth: CGFloat = 70
    static let deleteButtonWidth: CGFloat = 20
}

/// Which sidebar row is showing in the detail pane. A monitor is
/// addressed by id, not index, so a row that gets removed from
/// `settings.monitors` (via "Remove Monitor") cleanly falls out of
/// `List(selection:)` instead of pointing at a stale/renumbered index.
private enum SettingsSection: Hashable {
    case mqtt
    case general
    case monitor(UUID)
}

/// A macOS System Settings / BetterDisplay-style sidebar + detail layout:
/// the sidebar lists MQTT Broker, General, and one row per configured
/// monitor, so the list of monitors can keep growing without every
/// monitor's whole input table being stacked into one long scroll (the
/// previous single-`Form` layout).
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    var onTestConnection: () -> Void
    var onManualRefreshInput: () -> Void

    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsSection.general)
                Label("MQTT", systemImage: "network")
                    .tag(SettingsSection.mqtt)

                Section("Monitors") {
                    ForEach(store.settings.monitors) { monitor in
                        Label(monitor.name.isEmpty ? "Monitor" : monitor.name, systemImage: "display")
                            .tag(SettingsSection.monitor(monitor.id))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            // The window has no title bar strip (see
            // SettingsWindowController) - its traffic-light buttons float
            // over the sidebar's own top-left corner instead, so the
            // first row needs this much clearance to not sit under them.
            .safeAreaInset(edge: .top) {
                Color.clear.frame(height: 28)
            }
        } detail: {
            ScrollView {
                detailView
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 720, height: 480)
        // NavigationSplitView renders its own title in the window-toolbar
        // area - independently of the NSWindow's own titleVisibility/
        // titlebarAppearsTransparent settings - defaulting to the
        // NSWindow's `title` when no navigationTitle is set. Both of these
        // are needed to actually remove the visible text: hiding the
        // toolbar alone left the title showing.
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
        // If the selected monitor gets removed (via "Remove Monitor"),
        // fall back to a section that's guaranteed to still exist rather
        // than showing an empty detail pane for a dangling selection.
        .onChange(of: store.settings.monitors.map(\.id)) { ids in
            if case .monitor(let id) = selection, !ids.contains(id) {
                selection = .mqtt
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .mqtt, .none:
            MQTTBrokerSettings(store: store, onTestConnection: onTestConnection)
        case .general:
            GeneralSettings(store: store, onManualRefreshInput: onManualRefreshInput)
        case .monitor(let id):
            if let index = store.settings.monitors.firstIndex(where: { $0.id == id }) {
                MonitorSettings(
                    monitor: $store.settings.monitors[index],
                    onRemove: { store.settings.monitors.remove(at: index) }
                )
            }
        }
    }
}

private struct MQTTBrokerSettings: View {
    @ObservedObject var store: SettingsStore
    var onTestConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MQTT")
                .font(.title2.bold())

            ToggleRow(label: "Enable MQTT", isOn: $store.settings.mqttEnabled)

            if store.settings.mqttEnabled {
                FormRow("Status") {
                    LiveStatusLabel(connected: store.mqttConnected)
                }
            } else {
                FormRow("") {
                    Text("MQTT is off - the app won't connect to a broker, read the stored password, publish state, or accept remote commands. Menu bar switching still works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Fieldset {
                FormRow("Server") {
                    PlainTextField(text: $store.settings.mqttHost, placeholder: "mqtt.example.com")
                }
                FormRow("Port") {
                    PlainTextField(text: Binding(
                        get: { String(store.settings.mqttPort) },
                        set: { store.settings.mqttPort = Int($0.filter(\.isNumber)) ?? 0 }
                    ))
                }
                ToggleRow(label: "Use TLS", isOn: $store.settings.mqttUseTLS)
                FormRow("Username") {
                    PlainTextField(text: $store.settings.mqttUsername, placeholder: "optional")
                }
                FormRow("Password") {
                    PlainTextField(text: $store.mqttPassword, isSecure: true, placeholder: "optional")
                }
                FormRow("Topic") {
                    PlainTextField(text: $store.settings.mqttTopic, placeholder: "home/monitor/input")
                }
                FormRow("") {
                    Text("State is published (retained) on this topic; commands are read from \"<topic>/set\". With more than one monitor, each gets its own \"<topic>/<id>\" pair instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                FormRow("") {
                    Text("Changes on this screen are saved automatically as you type - there's no separate Save button.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                FormRow("") {
                    HStack {
                        ConnectionStatusLabel(result: store.connectionTestResult)
                        Spacer()
                        Button("Test Connection") { onTestConnection() }
                    }
                }
            }
            // The whole broker form is pointless to touch while MQTT is
            // off - disabling it (rather than just hiding it) keeps the
            // saved values visible for reference/next time it's turned on.
            .disabled(!store.settings.mqttEnabled)
            .opacity(store.settings.mqttEnabled ? 1 : 0.5)
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: SettingsStore
    var onManualRefreshInput: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General")
                .font(.title2.bold())

            Fieldset {
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
            }
        }
    }
}

private struct MonitorSettings: View {
    @Binding var monitor: MonitorConfig
    var onRemove: () -> Void

    // Editing the name in-place in the headline (pencil toggles this)
    // instead of a separate "Name" field below it, which just duplicated
    // the same value on screen.
    @State private var isEditingName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if isEditingName {
                        PlainTextField(text: $monitor.name)
                            .frame(maxWidth: 280)
                    } else {
                        Text(monitor.name.isEmpty ? "Monitor" : monitor.name)
                            .font(.title2.bold())
                    }
                    Button {
                        isEditingName.toggle()
                    } label: {
                        Image(systemName: isEditingName ? "checkmark.circle.fill" : "square.and.pencil")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isEditingName ? "Confirm name" : "Edit name")
                }

                if let serialNumber = monitor.edidSerialNumber {
                    Text("Serial: \(serialNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Fieldset {
                InputMappingRows(inputs: $monitor.inputs)

                HStack {
                    Button {
                        monitor.inputs.append(InputMapping(name: "New Input", mqttValue: "", vcpValue: 0))
                    } label: {
                        Label("Add Input", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    // Removes this monitor's whole configuration - for one
                    // that's been permanently disconnected/sold. A monitor
                    // that's just temporarily unplugged shouldn't be
                    // removed here: it keeps its config (and VCP mappings)
                    // and gets matched again the next time it's detected.
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove Monitor", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Text("Map incoming MQTT payload values to a DDC/CI input-source (VCP 0x60) value. These also appear in the menu bar dropdown, with each monitor's current input highlighted. VCP values for the same port can differ between monitor models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A single settings row: a fixed-width, trailing-aligned label followed
/// by content that fills the rest of the row's width. Every row - across
/// every detail pane - uses the exact same `Layout.labelWidth`, so all the
/// label text lines up on one edge and all the fields/controls line up on
/// the other, independent of label text length or control type.
/// An HTML `<fieldset>`-style bordered box grouping a set of form rows -
/// used for every field group in Settings so related controls (the MQTT
/// broker fields, a monitor's inputs, ...) read as one visually
/// contained unit rather than just floating in the page.
private struct Fieldset<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 10) {
            content
        }
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

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

/// The app's actual, live MQTT connection state - distinct from
/// `ConnectionStatusLabel`, which only shows the result of a one-off
/// "Test Connection" click and otherwise stays blank. This is always
/// visible so it's clear whether the broker connection is currently up,
/// without having to click anything.
private struct LiveStatusLabel: View {
    let connected: Bool

    var body: some View {
        Label(connected ? "Connected" : "Disconnected", systemImage: connected ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(connected ? .green : .secondary)
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
                    PlainTextField(text: $input.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PlainTextField(text: $input.mqttValue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PlainTextField(text: Binding(
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
                    .help("Remove this input")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `TextField`/`SecureField` render their content right-aligned when
/// placed inside a `Form` with `.formStyle(.grouped)` on macOS -
/// `.multilineTextAlignment(.leading)` has no effect on that. A plain
/// `NSTextField`/`NSSecureTextField` sidesteps it; its chrome (border/
/// corner radius) is drawn here in SwiftUI to match `.roundedBorder`'s
/// look, with the underlying field left completely unstyled (no native
/// bezel/background) and used only for text input and alignment. Every
/// text field in this form uses this same component so they all render
/// identically.
private struct PlainTextField: View {
    @Binding var text: String
    var isSecure: Bool = false
    var placeholder: String? = nil

    var body: some View {
        PlainTextFieldRepresentable(text: $text, isSecure: isSecure, placeholder: placeholder)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 5.5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

private struct PlainTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    var isSecure: Bool
    var placeholder: String?

    func makeNSView(context: Context) -> NSTextField {
        let field = isSecure ? NSSecureTextField() : NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .left
        field.placeholderString = placeholder
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
