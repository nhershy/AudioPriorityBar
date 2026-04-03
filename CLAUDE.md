# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build release (universal binary, unsigned) → dist/AudioPriorityBar.app
./build.sh

# Build via xcodebuild directly
xcodebuild -scheme AudioPriorityBar -configuration Release -derivedDataPath .build build
```

No test targets exist in this project.

## Architecture

Audio Priority Bar is a macOS menu bar utility (SwiftUI, macOS 13+) that auto-switches audio devices based on user-defined priority. It runs as a `MenuBarExtra` with `LSUIElement: true` (no dock icon).

### Core Data Flow

```
CoreAudio device/volume/mute events
  → AudioDeviceService (listeners + CoreAudio API wrapper)
    → AudioManager (@StateObject, central state)
      → @Published properties
        → SwiftUI Views re-render
```

### Key Components

- **`AudioPriorityBarApp.swift`** — App entry point, contains `AudioManager` (the central ObservableObject), `MenuBarLabel`, and `VolumeMeterView`. This is the largest file and holds most business logic.
- **`AudioDeviceService.swift`** — CoreAudio wrapper: device enumeration, default device get/set, volume control, and change listeners via `AudioObjectPropertyListenerBlock`.
- **`PriorityManager.swift`** — UserDefaults persistence for priority lists, known devices, device categories, mode state, hidden/never-use devices.
- **`HeadphoneDetection.swift`** — Keyword-based auto-categorization of devices as headphones (100+ brand keywords).
- **`LaunchAtLoginManager.swift`** — `SMAppService` integration for launch-at-login.

### Views

- **`MenuBarView.swift`** — Main popover: mode toggle, volume slider, device sections.
- **`DeviceListView.swift`** — Draggable device rows with reorder, category assignment, and context menus.

### Mode System

Three modes control auto-switching behavior:
- **Speaker mode** — shows/auto-switches among speaker-categorized devices
- **Headphone mode** — shows/auto-switches among headphone-categorized devices  
- **Custom mode** — shows all devices, disables auto-switching

Connecting a headphone auto-switches to headphone mode; disconnecting all headphones reverts to speaker mode.

### Persistence

All state stored in UserDefaults keyed by device UID. Separate priority lists for inputs, speakers, and headphones. Devices are remembered with "last seen" timestamps even when disconnected.

## Bundle Info

- Identifier: `app.audioprioritybar`
- Minimum deployment: macOS 13.0
