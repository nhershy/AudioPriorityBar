# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build release (universal binary, unsigned) → dist/AudioPriorityBar.app
./build.sh

# Build via xcodebuild directly
xcodebuild -scheme AudioPriorityBar -configuration Release -derivedDataPath .build build
```

## Tests

```bash
# Logic tests (ranking, reordering, UID changes, migration)
Tests/run.sh
```

There is no Xcode test target. `Tests/run.sh` compiles `Services/PriorityLogic.swift` (Foundation only) together with `Tests/PriorityLogicTests.swift` using `swiftc`. Keep `PriorityLogic.swift` free of CoreAudio, SwiftUI and UserDefaults so this keeps working.

New source files must be added to `AudioPriorityBar.xcodeproj/project.pbxproj` by hand (explicit file references, hand-numbered IDs).

## Architecture

Audio Priority Bar is a macOS menu bar utility (SwiftUI, macOS 13+) that keeps the system default audio devices on the highest-ranked connected device. It runs as a `MenuBarExtra` with `LSUIElement: true` (no dock icon).

### Core Data Flow

```
CoreAudio device/default/volume/mute events
  → AudioDeviceService (listeners + CoreAudio API wrapper)
    → AudioManager (@StateObject, central state)
      → PriorityManager / PriorityLogic (which device should be in use)
      → @Published properties
        → SwiftUI Views re-render
```

### Key Components

- **`AudioPriorityBarApp.swift`** — App entry point and the menu bar icon.
- **`Services/AudioManager.swift`** — The central `ObservableObject`. Builds the lists the UI shows and, in `enforcePriorities()`, sets the system default input/output. Takes its `AudioDeviceService` and `PriorityManager` as init parameters so both can be replaced.
- **`Services/AudioDeviceService.swift`** — CoreAudio wrapper: device enumeration, default device get/set, volume, mute, transport type, and change listeners via `AudioObjectPropertyListenerBlock`.
- **`Services/PriorityManager.swift`** — UserDefaults persistence (in-memory state, written on every change): ranked order per direction, ignored devices, known devices, auto-switch flag. Runs the one-time migration from the old schema.
- **`Services/PriorityLogic.swift`** — Pure functions: `mergeReorder`, `pickTarget`, `adoptStaleUIDs`, `migrateV1`. Also defines `StoredDevice`.
- **`Models/Headphones.swift`** — Headphone name keywords. Only used for row icons and migration ordering; it never decides which device is used.
- **`Services/LaunchAtLoginManager.swift`** — `SMAppService` integration for launch-at-login.

### Views

- **`MenuBarView.swift`** — Main popover: Auto-switch toggle, volume slider, Output and Input sections, footer ("not connected · ignored" disclosure, info, gear menu).
- **`DeviceListView.swift`** — Device rows, drag-to-reorder, and the row menu (Ignore / Stop Ignoring / Forget).

### Behavior

- Two ranked lists, Output and Input. There are no speaker/headphone modes.
- **Auto-switch on**: the highest-ranked connected, non-ignored device of each list is enforced on every device or default-device change, 1.5s after the last change (Bluetooth profile switches), and on wake. Clicking a row does nothing; outside changes are reverted. Both were explicit product decisions.
- **Auto-switch off**: nothing is enforced; clicking a row selects it.
- New devices are appended to the bottom of their list.
- Reordering goes through `PriorityLogic.mergeReorder`, so devices that are not shown (disconnected or ignored) keep their rank.

### Persistence

UserDefaults, schema version 2 (`schemaVersion`). Keys: `devices` (JSON `[StoredDevice]`, keyed by UID + direction), `inputOrder`, `outputOrder`, `ignoredInputs`, `ignoredOutputs`, `autoSwitchEnabled`.

The earlier schema (`knownDevices`, `inputPriorities`, `speakerPriorities`, `headphonePriorities`, `deviceCategories`, `hiddenMics`, `hiddenSpeakers`, `hiddenHeadphones`, `neverUseDevices`, `currentMode`, `customMode`) is read once by the migration and never modified.

Row identity in SwiftUI lists must be the device UID: every disconnected device has `AudioObjectID` 0.

## Bundle Info

- Identifier: `app.audioprioritybar`
- Minimum deployment: macOS 13.0
