# Monitor Input Switcher (macOS)

A tiny menu bar app that subscribes to an MQTT topic and uses DDC/CI to
switch an external monitor's input source whenever a matching value
arrives. Built for a Dell P2725QE, but works with any DDC/CI-capable
monitor.

## What it does

- Runs as a menu bar item only (no Dock icon, no window on launch).
- Connects to your MQTT broker and subscribes to one topic.
- Maps incoming payload values (e.g. `"hdmi"`) to a DDC/CI VCP input
  value (e.g. `17`) and writes it to VCP feature `0x60` (Input Source)
  on the monitor.
- Lets you define named inputs (`HDMI = 17`, `DisplayPort = 15`, ...)
  that also show up in the menu so you can switch inputs by hand.
- Reads the monitor's current input back via DDC/CI and highlights it
  (checkmark) in the menu.
- Can start automatically at login.

## Requirements

- macOS 13 (Ventura) or newer.
- Xcode Command Line Tools (`xcode-select --install`) - no full Xcode
  needed to build.
- A DDC/CI-capable external monitor connected via HDMI/DisplayPort/
  Thunderbolt (not the built-in display).

## Build & run

```bash
cd mac
./Scripts/build_app.sh
open build/MonitorInputSwitcher.app
```

The script builds a release binary, assembles
`build/MonitorInputSwitcher.app`, and ad-hoc code-signs it (no paid
Apple Developer account needed for local use). Move the `.app` to
`/Applications` if you want it to stick around and be picked up by
"Start at Login".

The first launch may show a Gatekeeper warning since the app isn't
notarized; right-click → Open once to allow it.

## Configuring

Click the menu bar icon (a display glyph) → **Settings…**:

- **MQTT Broker**: host, port, optional TLS, optional username/
  password (the password is stored in the macOS Keychain, never in
  the settings file), and the topic to subscribe to.
- **Inputs**: rows of `Name / MQTT value / VCP value`. When a message
  arrives on the topic whose payload matches an input's "MQTT value"
  (case-insensitive), the app writes that input's VCP value to the
  monitor. The same rows populate the menu's quick-switch list.
- **Start at Login** toggle.

Settings are stored as JSON at
`~/Library/Application Support/MonitorInputSwitcher/settings.json`
(the MQTT password is kept separately in the Keychain).

### Dell P2725QE input values

The Dell P2725QE's standard DDC/CI (VCP `0x60`) input source values are
typically:

| Input        | VCP value |
|--------------|-----------|
| HDMI 1       | 17 (0x11) |
| HDMI 2       | 18 (0x12) |
| DisplayPort  | 15 (0x0F) |
| USB-C        | 27 (0x1B) |

These can vary by firmware, so if a value doesn't switch the input you
expect, use "Refresh Current Input Now" in Settings after manually
switching inputs on the monitor's own OSD to see which VCP value the
monitor reports back, and adjust the mapping accordingly (see
Troubleshooting below for how to read the value from logs).

## How input switching works technically

- On Apple Silicon Macs, DDC/CI is sent through the private
  `IOAVService` API that the display co-processor exposes per external
  display (the same mechanism apps like MonitorControl use).
- On Intel Macs, it uses Apple's public `IOFBCopyI2CInterfaceForBus` /
  `IOI2CSendRequest` API (`IOKit/i2c/IOI2CInterface.h`).
- Both are wrapped in `DDCTransport`; `DDCController` builds/parses the
  VESA MCCS "Set VCP Feature" / "Get VCP Feature" packets and picks
  the first external display it finds a transport for. If you have
  more than one external monitor connected, the app currently controls
  whichever one is discovered first - per-display targeting for
  multi-monitor setups isn't implemented yet.

## Troubleshooting

Open **Console.app** and filter by subsystem
`com.markowieck.MonitorInputSwitcher` (or run the command below) to see
what the app is doing:

```bash
log stream --predicate 'subsystem == "com.markowieck.MonitorInputSwitcher"' --info
```

- `"No controllable external display found"` - the app couldn't find
  any display exposing a DDC/CI-capable interface. Make sure the
  monitor isn't the built-in display and is connected via a port that
  carries DDC (some USB-C docks/hubs don't pass DDC through).
- `"getCurrentInput: failed to parse reply ..."` followed by a hex
  dump - the monitor responded, but not with a reply the app
  recognizes as a valid VCP feature reply. This can happen with some
  monitors/firmware, or on non-standard hardware/GPU driver setups
  where the DDC passthrough isn't fully implemented. Reading the
  current input is only used for the checkmark in the menu; try
  "switching" an input from the menu even if reading fails - writing
  and reading are independent operations.
- MQTT connection issues show as `"MQTT connect failed: ..."` with the
  underlying error - use the "Test Connection" button in Settings to
  retry and see the result inline.

## Project layout

```
mac/
  Package.swift
  Sources/MonitorInputSwitcher/
    main.swift, AppDelegate.swift        - app entry / coordination
    Models/                              - Settings, InputMapping
    Services/
      DDC/                               - DDC/CI protocol + transports
      MQTTService.swift                  - MQTTNIO wrapper
      SettingsStore.swift, KeychainStore.swift
      LoginItemService.swift             - SMAppService login item
    UI/                                  - status bar menu + Settings window
  Resources/Info.plist
  Scripts/build_app.sh
```
