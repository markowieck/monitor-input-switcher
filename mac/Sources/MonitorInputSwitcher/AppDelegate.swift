import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let ddc = DDCController()
    private let mqtt = MQTTService()

    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?
    private var connectionProbe: MQTTService?
    private var cancellables = Set<AnyCancellable>()

    private var pollTimer: Timer?

    /// Currently detected monitors, keyed by `MonitorConfig.id`. A
    /// `MonitorConfig` that exists in settings but isn't a key here is
    /// just not actionable right now (e.g. temporarily unplugged) - it
    /// keeps its saved input mappings and gets matched again once
    /// detected.
    private var liveTransports: [UUID: DDCTransport] = [:]
    private var currentVCPValues: [UUID: Int] = [:]
    private var lastPublishedVCPValues: [UUID: Int] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpMainMenu()

        matchMonitors(with: ddc.refreshTransports())

        statusBar = StatusBarController(settingsStore: settingsStore, ddc: ddc)
        statusBar?.onSelectInput = { [weak self] monitor, input in self?.applyInput(monitor: monitor, input: input) }
        statusBar?.onOpenSettings = { [weak self] in self?.showSettings() }
        statusBar?.onQuit = { NSApp.terminate(nil) }
        statusBar?.onRefreshCurrentInput = { [weak self] in self?.refreshCurrentInput() }

        mqtt.onValue = { [weak self] commandTopic, value in self?.handleMQTTValue(commandTopic: commandTopic, value: value) }
        mqtt.onConnectionStateChanged = { [weak self] connected in
            self?.statusBar?.setMQTTConnected(connected)
            self?.settingsStore.mqttConnected = connected
            if connected {
                self?.publishAllDiscoveryConfigs()
                // Re-assert current state on every (re)connect, bypassing
                // the dedupe below - covers the startup race where the DDC
                // probe resolves before MQTT finishes connecting (the
                // state publish then silently no-ops on an empty topic
                // and would otherwise never be retried), and re-primes a
                // retained value the broker may have lost.
                self?.publishAllCurrentInputs(force: true)
            }
        }

        settingsStore.$settings
            // Settings fields are bound live to the Settings UI, so every
            // keystroke publishes a new value - debounce so we don't tear
            // down/reconnect MQTT (and hammer partially-typed hostnames)
            // on every character typed.
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .removeDuplicates { old, new in
                old.mqttEnabled == new.mqttEnabled &&
                old.mqttHost == new.mqttHost &&
                old.mqttPort == new.mqttPort &&
                old.mqttUseTLS == new.mqttUseTLS &&
                old.mqttUsername == new.mqttUsername &&
                old.mqttTopic == new.mqttTopic &&
                // The topic scheme only depends on *which* monitors exist
                // (their count/ids, see topics(for:in:)), not their
                // names/inputs - those are handled by the discovery-only
                // sink below, without tearing down the MQTT connection.
                old.monitors.map(\.id) == new.monitors.map(\.id)
            }
            .sink { [weak self] settings in
                guard let self else { return }
                guard settings.mqttEnabled else {
                    self.mqtt.stop()
                    self.statusBar?.setMQTTConnected(false)
                    self.settingsStore.mqttConnected = false
                    return
                }
                self.mqtt.start(
                    settings: settings,
                    password: self.settingsStore.mqttPassword,
                    commandTopics: settings.monitors.map { self.topics(for: $0, in: settings).command }
                )
            }
            .store(in: &cancellables)

        // Monitor names/inputs can change independently of the broker
        // settings above; when that happens, re-publish the Home
        // Assistant discovery configs so their `options` lists stay in
        // sync. dropFirst() skips the initial value $settings emits on
        // subscribe - that case is already covered by the (re)connect
        // handler above, and firing here too would just race it before
        // MQTT has actually connected.
        settingsStore.$settings
            .map(\.monitors)
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishAllDiscoveryConfigs() }
            .store(in: &cancellables)

        LoginItemService.setEnabled(settingsStore.settings.launchAtLogin)

        refreshCurrentInput()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshCurrentInput()
        }
    }

    private func applyInput(monitor: MonitorConfig, input: InputMapping) {
        guard let initialTransport = liveTransports[monitor.id] else {
            NSLogError("applyInput: no live transport for \(monitor.name)")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if self.ddc.setInput(on: initialTransport, vcpValue: input.vcpValue) {
                DispatchQueue.main.async { self.didApplyInput(monitor: monitor, input: input) }
                return
            }

            // Failed after DDCController's own retries - rescan in case
            // the monitor was replugged and got a new underlying
            // io_service (the cached transport now points at a dead
            // one), then retry once against whatever now matches it.
            NSLogError("applyInput: write failed for \(monitor.name), rescanning for a different transport")
            let transports = self.ddc.refreshTransports()
            DispatchQueue.main.async {
                self.matchMonitors(with: transports)
                guard let retriedTransport = self.liveTransports[monitor.id] else {
                    NSLogError("Failed to switch \(monitor.name) input to \(input.name) - monitor no longer detected")
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = self.ddc.setInput(on: retriedTransport, vcpValue: input.vcpValue)
                    DispatchQueue.main.async {
                        if ok {
                            self.didApplyInput(monitor: monitor, input: input)
                        } else {
                            NSLogError("Failed to switch \(monitor.name) input to \(input.name) after rescan")
                        }
                    }
                }
            }
        }
    }

    private func didApplyInput(monitor: MonitorConfig, input: InputMapping) {
        NSLogInfo("Switched \(monitor.name) input to \(input.name) (VCP \(input.vcpValue))")
        currentVCPValues[monitor.id] = input.vcpValue
        statusBar?.setCurrentVCPValue(input.vcpValue, for: monitor.id)
        publishCurrentInput(monitor: monitor, vcpValue: input.vcpValue)
    }

    private func handleMQTTValue(commandTopic: String, value: String) {
        let settings = settingsStore.settings
        guard let monitor = settings.monitors.first(where: { topics(for: $0, in: settings).command == commandTopic }) else {
            NSLogError("Received MQTT value \"\(value)\" on unrecognized command topic \(commandTopic)")
            return
        }
        guard let input = monitor.inputs.first(where: { $0.mqttValue.caseInsensitiveCompare(value) == .orderedSame }) else {
            NSLogError("Received MQTT value \"\(value)\" for \(monitor.name) with no matching input mapping")
            return
        }
        applyInput(monitor: monitor, input: input)
    }

    /// Refreshes every currently-known monitor's current input. Uses the
    /// already-validated cached transports (fast - just a per-monitor DDC
    /// read) rather than rescanning on every call: this runs on every
    /// menu open and every 60s poll, and a full rescan means re-probing
    /// every candidate I2C bus with retries, which took several seconds
    /// in testing. Only falls back to a full rescan when no monitor is
    /// currently known at all (nothing detected yet, or all lost).
    private func refreshCurrentInput() {
        guard !liveTransports.isEmpty else {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let transports = self.ddc.refreshTransports()
                DispatchQueue.main.async {
                    self.matchMonitors(with: transports)
                    self.readAllCurrentInputs()
                }
            }
            return
        }
        readAllCurrentInputs()
    }

    private func readAllCurrentInputs() {
        for (monitorID, transport) in liveTransports {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let value = self.ddc.getCurrentInput(from: transport)
                NSLogInfo("refreshCurrentInput: \(transport.displayName) parsed VCP value = \(String(describing: value))")
                DispatchQueue.main.async {
                    self.currentVCPValues[monitorID] = value
                    self.statusBar?.setCurrentVCPValue(value, for: monitorID)
                    if let monitor = self.settingsStore.settings.monitors.first(where: { $0.id == monitorID }) {
                        self.publishCurrentInput(monitor: monitor, vcpValue: value)
                    }
                }
            }
        }
    }

    /// Matches each live transport to a `MonitorConfig` - by an existing
    /// `transportKey`, else an unassigned placeholder (see
    /// `MonitorConfig.transportKey`), else a newly created config - and
    /// persists any resulting settings change. Must run on the main
    /// thread (mutates `settingsStore.settings`); `transports` itself
    /// should come from a background-thread `ddc.refreshTransports()`
    /// call, since that call can block for seconds.
    private func matchMonitors(with transports: [DDCTransport]) {
        var settings = settingsStore.settings
        let detectedNames = externalDisplayNames()
        var claimed = Set<UUID>()
        var newLiveTransports: [UUID: DDCTransport] = [:]
        var settingsChanged = false

        for (index, transport) in transports.enumerated() {
            // Best-effort: NSScreen has no public API to tie a specific
            // I2C bus back to a specific CGDirectDisplayID on Intel Macs
            // (see IntelDDCTransport), so this pairs them positionally.
            // Correct as long as both APIs enumerate displays in the same
            // order - always true for one external monitor, not
            // guaranteed once there's more than one.
            let detectedName = index < detectedNames.count ? detectedNames[index] : transport.displayName

            if let existingIndex = settings.monitors.firstIndex(where: { $0.transportKey == transport.displayName }) {
                let id = settings.monitors[existingIndex].id
                claimed.insert(id)
                newLiveTransports[id] = transport
                continue
            }

            if let placeholderIndex = settings.monitors.firstIndex(where: { $0.transportKey.isEmpty && !claimed.contains($0.id) }) {
                settings.monitors[placeholderIndex].transportKey = transport.displayName
                if settings.monitors[placeholderIndex].name.isEmpty || settings.monitors[placeholderIndex].name == "Monitor" {
                    settings.monitors[placeholderIndex].name = detectedName
                }
                let id = settings.monitors[placeholderIndex].id
                claimed.insert(id)
                newLiveTransports[id] = transport
                settingsChanged = true
                continue
            }

            let newMonitor = MonitorConfig(transportKey: transport.displayName, name: detectedName, inputs: Settings.defaultInputTemplate())
            settings.monitors.append(newMonitor)
            claimed.insert(newMonitor.id)
            newLiveTransports[newMonitor.id] = transport
            settingsChanged = true
            NSLogInfo("matchMonitors: new monitor detected, added config for \(detectedName) (\(transport.displayName))")
        }

        liveTransports = newLiveTransports
        if settingsChanged {
            settingsStore.settings = settings
        }
    }

    /// Every connected external display's name (from its EDID, via
    /// ColorSync/CoreGraphics), in `NSScreen.screens` order - works
    /// uniformly on Intel and Apple Silicon, unlike a DDC transport's own
    /// `displayName` (which on Intel is just an IOFramebuffer bus label).
    private func externalDisplayNames() -> [String] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            guard CGDisplayIsBuiltin(displayID) == 0 else { return nil }
            return screen.localizedName
        }
    }

    /// A monitor's state/command topics. With exactly one monitor
    /// configured, these are exactly `settings.mqttTopic` /
    /// `settings.mqttTopic + "/set"` - unchanged from before multi-monitor
    /// support, so existing single-monitor Home Assistant setups keep
    /// working without any reconfiguration. Once a second monitor is
    /// added, every monitor (including the first) moves to its own
    /// "<topic>/<id>" / ".../set" pair - see `publishDiscoveryConfig`.
    private func topics(for monitor: MonitorConfig, in settings: Settings) -> (state: String, command: String) {
        let base = settings.mqttTopic
        guard settings.monitors.count > 1 else {
            return (base, base + "/set")
        }
        let slug = monitor.id.uuidString.prefix(8).lowercased()
        return ("\(base)/\(slug)", "\(base)/\(slug)/set")
    }

    /// Publishes the current input to a monitor's MQTT state topic.
    /// Normally only when it actually changed since the last publish -
    /// this runs on every menu open and on a 60s poll, and republishing
    /// an unchanged value on every tick would be pointless traffic. Pass
    /// `force: true` to bypass that and publish regardless (see the
    /// (re)connect handler above for why that's needed).
    private func publishCurrentInput(monitor: MonitorConfig, vcpValue: Int?, force: Bool = false) {
        guard let vcpValue, force || vcpValue != lastPublishedVCPValues[monitor.id],
            let input = monitor.inputs.first(where: { $0.vcpValue == vcpValue })
        else { return }
        lastPublishedVCPValues[monitor.id] = vcpValue
        let (stateTopic, _) = topics(for: monitor, in: settingsStore.settings)
        mqtt.publish(topic: stateTopic, value: input.mqttValue)
    }

    private func publishAllCurrentInputs(force: Bool) {
        let settings = settingsStore.settings
        for monitor in settings.monitors {
            publishCurrentInput(monitor: monitor, vcpValue: currentVCPValues[monitor.id], force: force)
        }
    }

    private func publishAllDiscoveryConfigs() {
        let settings = settingsStore.settings
        for monitor in settings.monitors {
            publishDiscoveryConfig(for: monitor, in: settings)
        }
    }

    /// Publishes the Home Assistant MQTT Discovery config for one
    /// monitor's input `select` entity. With a single monitor configured,
    /// `uniqueId` is exactly `monitor_input_switcher_<clientIdSuffix>` -
    /// unchanged from before multi-monitor support, so the entity already
    /// set up in Home Assistant keeps its identity. Adding a second
    /// monitor changes every monitor's uniqueId/topics (see `topics`),
    /// which leaves the original entity's old discovery config orphaned
    /// in HA (retained, but no longer referenced) - remove it there
    /// manually if that happens.
    private func publishDiscoveryConfig(for monitor: MonitorConfig, in settings: Settings) {
        let options = monitor.inputs.map(\.mqttValue).filter { !$0.isEmpty }
        guard !options.isEmpty else { return }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let (stateTopic, commandTopic) = topics(for: monitor, in: settings)
        let uniqueId = settings.monitors.count > 1
            ? "monitor_input_switcher_\(settings.clientIdSuffix)_\(monitor.id.uuidString.prefix(8).lowercased())"
            : "monitor_input_switcher_\(settings.clientIdSuffix)"
        mqtt.publishDiscovery(
            uniqueId: uniqueId,
            name: "\(monitor.name) Input",
            deviceName: monitor.name,
            appVersion: appVersion,
            stateTopic: stateTopic,
            commandTopic: commandTopic,
            options: options
        )
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                store: settingsStore,
                onTestConnection: { [weak self] in self?.testMQTTConnection() },
                onManualRefreshInput: { [weak self] in self?.refreshCurrentInput() }
            )
        }
        settingsWindow?.show()
    }

    private func testMQTTConnection() {
        connectionProbe?.stop()

        settingsStore.connectionTestResult = "Connecting…"
        let probe = MQTTService()
        connectionProbe = probe
        probe.onConnectionStateChanged = { [weak self, weak probe] connected in
            self?.settingsStore.connectionTestResult = connected ? "Connected ✓" : "Connection failed"
            if connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    probe?.stop()
                }
            }
        }
        probe.start(settings: settingsStore.settings, password: settingsStore.mqttPassword)
    }

    /// This app has no Xcode-generated main menu (no MainMenu.xib / no
    /// SwiftUI `App` scene), so without this, standard editing shortcuts
    /// like Cmd+C/Cmd+V/Cmd+A don't reliably reach text fields in the
    /// Settings window. A minimal Edit menu with the standard
    /// selectors/key equivalents, targeted at the first responder, is
    /// enough to enable them.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Monitor Input Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
