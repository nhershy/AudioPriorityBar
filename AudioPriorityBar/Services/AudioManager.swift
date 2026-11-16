import SwiftUI
import CoreAudio
import AppKit

/// Central state of the app. Watches CoreAudio through `AudioDeviceService`, keeps the lists
/// the UI shows, and, while auto-switching is on, keeps the system default input and output
/// on the highest-ranked connected device.
@MainActor
final class AudioManager: ObservableObject {
    /// Devices shown in each ranked list, in priority order. Connected devices only, plus
    /// remembered but disconnected ones while `showAllDevices` is on. Never includes ignored devices.
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var inputDevices: [AudioDevice] = []
    /// Ignored devices, filled only while `showAllDevices` is on.
    @Published private(set) var ignoredOutputDevices: [AudioDevice] = []
    @Published private(set) var ignoredInputDevices: [AudioDevice] = []
    /// Row counts behind the "not connected · ignored" disclosure, across both lists.
    @Published private(set) var notConnectedCount = 0
    @Published private(set) var ignoredCount = 0

    @Published private(set) var currentInputId: AudioObjectID?
    @Published private(set) var currentOutputId: AudioObjectID?
    @Published private(set) var isAutoEnabled: Bool
    @Published private(set) var showAllDevices = false
    @Published private(set) var volume: Float = 0
    @Published private(set) var volumeSupported = true
    @Published private(set) var mutedDeviceIds: Set<AudioObjectID> = []

    private let deviceService: AudioDeviceService
    private let priorityManager: PriorityManager
    private var connectedDevices: [AudioDevice] = []
    private var deviceSettleTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(deviceService: AudioDeviceService = AudioDeviceService(),
         priorityManager: PriorityManager = PriorityManager()) {
        self.deviceService = deviceService
        self.priorityManager = priorityManager
        isAutoEnabled = priorityManager.isAutoSwitchEnabled

        refreshDevices()
        refreshVolume()
        refreshMuteStatus()
        startListening()
        enforcePriorities()
    }

    // MARK: - What the UI reads

    var isOutputMuted: Bool {
        currentOutputId.map { mutedDeviceIds.contains($0) } ?? false
    }

    func isActive(_ device: AudioDevice) -> Bool {
        device.isConnected && device.id == (device.type == .input ? currentInputId : currentOutputId)
    }

    func isMuted(_ device: AudioDevice) -> Bool {
        device.isConnected && mutedDeviceIds.contains(device.id)
    }

    func lastSeenText(for device: AudioDevice) -> String? {
        guard !device.isConnected else { return nil }
        return priorityManager.storedDevice(uid: device.uid, type: device.type)?.lastSeenRelative
    }

    // MARK: - What the UI does

    func setAutoEnabled(_ enabled: Bool) {
        isAutoEnabled = enabled
        priorityManager.isAutoSwitchEnabled = enabled
        if enabled {
            refreshDevices()
            enforcePriorities()
        }
    }

    func setShowAllDevices(_ show: Bool) {
        showAllDevices = show
        refreshDevices()
    }

    /// Uses `device` now. Only meaningful while auto-switching is off; with it on, the
    /// ranked order decides and the next enforcement would undo the choice.
    func selectDevice(_ device: AudioDevice) {
        guard !isAutoEnabled, device.isConnected else { return }
        guard deviceService.setDefaultDevice(device.id, type: device.type) else { return }
        if device.type == .input {
            currentInputId = device.id
        } else {
            currentOutputId = device.id
        }
        refreshVolume()
        refreshMuteStatus()
    }

    /// Moves a row of the shown list. `destination` is the gap index, as in `Array.move`.
    func moveDevice(type: AudioDeviceType, from source: Int, to destination: Int) {
        var devices = type == .input ? inputDevices : outputDevices
        guard devices.indices.contains(source) else { return }
        devices.move(fromOffsets: IndexSet(integer: source), toOffset: destination)

        priorityManager.saveVisibleOrder(devices, type: type)
        refreshDevices()
        enforcePriorities()
    }

    func setIgnored(_ device: AudioDevice, _ ignored: Bool) {
        priorityManager.setIgnored(device, ignored)
        refreshDevices()
        enforcePriorities()
    }

    func forgetDevice(_ device: AudioDevice) {
        guard !device.isConnected else { return }
        priorityManager.forgetDevice(device)
        refreshDevices()
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        deviceService.setOutputVolume(newVolume)
    }

    // MARK: - Reading system state

    private func refreshDevices() {
        connectedDevices = deviceService.getDevices()
        currentInputId = deviceService.getCurrentDefaultDevice(type: .input)
        currentOutputId = deviceService.getCurrentDefaultDevice(type: .output)

        var currentDefaults: [AudioDeviceType: String] = [:]
        for device in connectedDevices where device.id == (device.type == .input ? currentInputId : currentOutputId) {
            currentDefaults[device.type] = device.uid
        }
        priorityManager.rememberDevices(connectedDevices, currentDefaults: currentDefaults)

        var disconnectedRows = 0
        var ignoredRows = 0

        for type in AudioDeviceType.allCases {
            let connected = connectedDevices.filter { $0.type == type }
            let connectedUIDs = Set(connected.map(\.uid))
            let disconnected = priorityManager.knownDevices(type: type)
                .filter { !connectedUIDs.contains($0.uid) }
                .map(AudioDevice.disconnected)

            let everything = connected + disconnected
            let ignored = everything.filter { priorityManager.isIgnored($0) }
            disconnectedRows += disconnected.filter { !priorityManager.isIgnored($0) }.count
            ignoredRows += ignored.count

            let shown = (showAllDevices ? everything : connected).filter { !priorityManager.isIgnored($0) }
            let ranked = priorityManager.sortByPriority(shown, type: type)
            let ignoredShown = showAllDevices
                ? ignored.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                : []

            if type == .input {
                inputDevices = ranked
                ignoredInputDevices = ignoredShown
            } else {
                outputDevices = ranked
                ignoredOutputDevices = ignoredShown
            }
        }

        notConnectedCount = disconnectedRows
        ignoredCount = ignoredRows
    }

    private func refreshVolume() {
        volumeSupported = deviceService.deviceSupportsVolume()
        volume = deviceService.getOutputVolume()
    }

    private func refreshMuteStatus() {
        var muted: Set<AudioObjectID> = []
        for device in connectedDevices where deviceService.isDeviceMuted(device.id, type: device.type) {
            muted.insert(device.id)
        }
        mutedDeviceIds = muted
    }

    // MARK: - Enforcing the ranked order

    /// Makes the highest-ranked connected device the system default for input and output.
    /// Does nothing while auto-switching is off or when the right device is already in use.
    private func enforcePriorities() {
        guard isAutoEnabled else { return }

        for type in AudioDeviceType.allCases {
            let connected = connectedDevices.filter { $0.type == type }
            guard let targetUID = priorityManager.targetUID(type: type, connected: Set(connected.map(\.uid))),
                  let target = connected.first(where: { $0.uid == targetUID }) else { continue }

            let current = type == .input ? currentInputId : currentOutputId
            guard target.id != current, deviceService.setDefaultDevice(target.id, type: type) else { continue }

            if type == .input {
                currentInputId = target.id
            } else {
                currentOutputId = target.id
            }
        }

        refreshVolume()
        refreshMuteStatus()
    }

    // MARK: - Reacting to system changes

    private func startListening() {
        deviceService.onDevicesChanged = { [weak self] in
            Task { @MainActor in
                self?.handleDeviceChange()
            }
        }
        deviceService.onMuteOrVolumeChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshMuteStatus()
                self?.refreshVolume()
            }
        }
        deviceService.startListening()

        // Devices can come back in a different state after sleep without a change event.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDeviceChange()
            }
        }
    }

    /// A device appeared or disappeared, or something changed the system default device.
    private func handleDeviceChange() {
        refreshDevices()
        refreshMuteStatus()
        enforcePriorities()

        // Enforce once more after things settle. When Bluetooth headphones switch profile
        // (for example AirPods going from A2DP to HFP as a call starts) they briefly
        // disconnect, macOS falls back to another device, and the headphones may not be
        // ready yet when the first change arrives. The timer restarts on every change, so a
        // burst of changes ends in a single re-check.
        deviceSettleTimer?.invalidate()
        deviceSettleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDevices()
                self.refreshMuteStatus()
                self.enforcePriorities()
            }
        }
    }
}
