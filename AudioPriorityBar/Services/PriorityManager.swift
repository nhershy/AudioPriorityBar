import Foundation

/// Persists what the user has set up: the ranked input and output lists, ignored devices,
/// every device ever seen, and whether auto-switching is on.
///
/// State is read once and kept in memory; every change is written straight back to UserDefaults.
/// The decisions themselves live in `PriorityLogic`.
final class PriorityManager {
    private enum Key {
        static let schemaVersion = "schemaVersion"
        static let devices = "devices"
        static let inputOrder = "inputOrder"
        static let outputOrder = "outputOrder"
        static let ignoredInputs = "ignoredInputs"
        static let ignoredOutputs = "ignoredOutputs"
        static let autoSwitch = "autoSwitchEnabled"
    }

    /// Keys written by the Speakers / Headphones / Manual version. They are only read, never
    /// changed, so that version keeps working if it is launched again.
    private enum V1Key {
        static let knownDevices = "knownDevices"
        static let inputPriorities = "inputPriorities"
        static let speakerPriorities = "speakerPriorities"
        static let headphonePriorities = "headphonePriorities"
        static let deviceCategories = "deviceCategories"
        static let hiddenMics = "hiddenMics"
        static let hiddenSpeakers = "hiddenSpeakers"
        static let hiddenHeadphones = "hiddenHeadphones"
        static let neverUse = "neverUseDevices"
        static let customMode = "customMode"
    }

    private static let currentSchema = 2

    private let defaults: UserDefaults
    private var known: [StoredDevice] = []
    private var order: [AudioDeviceType: [String]] = [.input: [], .output: []]
    private var ignored: [AudioDeviceType: Set<String>] = [.input: [], .output: []]
    /// Devices connected at the last `rememberDevices` call, to timestamp the moment one leaves.
    private var lastConnected: [AudioDeviceType: Set<String>] = [.input: [], .output: []]

    var isAutoSwitchEnabled: Bool {
        didSet { defaults.set(isAutoSwitchEnabled, forKey: Key.autoSwitch) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.integer(forKey: Key.schemaVersion) >= Self.currentSchema {
            known = Self.decodeDevices(defaults.data(forKey: Key.devices))
            order[.input] = defaults.stringArray(forKey: Key.inputOrder) ?? []
            order[.output] = defaults.stringArray(forKey: Key.outputOrder) ?? []
            ignored[.input] = Set(defaults.stringArray(forKey: Key.ignoredInputs) ?? [])
            ignored[.output] = Set(defaults.stringArray(forKey: Key.ignoredOutputs) ?? [])
            isAutoSwitchEnabled = defaults.object(forKey: Key.autoSwitch) as? Bool ?? true
        } else {
            let migrated = PriorityLogic.migrateV1(Self.readV1(defaults), isHeadphoneName: HeadphoneDetection.isHeadphone)
            known = migrated.known
            order[.input] = migrated.inputOrder
            order[.output] = migrated.outputOrder
            ignored[.input] = Set(migrated.ignoredInputs)
            ignored[.output] = Set(migrated.ignoredOutputs)
            isAutoSwitchEnabled = migrated.autoSwitchEnabled

            saveDevices()
            saveOrder(.input)
            saveOrder(.output)
            saveIgnored(.input)
            saveIgnored(.output)
            defaults.set(isAutoSwitchEnabled, forKey: Key.autoSwitch)
            defaults.set(Self.currentSchema, forKey: Key.schemaVersion)
        }
    }

    // MARK: - Known devices

    /// Records the devices connected right now: refreshes their name and last-seen time,
    /// carries settings over to devices whose UID changed, and adds brand-new devices to the
    /// bottom of their list.
    ///
    /// `currentDefaults` is only used the very first time a list is filled: the device in use
    /// goes on top, so installing the app does not switch away from it.
    func rememberDevices(_ connected: [AudioDevice], currentDefaults: [AudioDeviceType: String] = [:]) {
        let now = Date()
        var changedTypes = Set<AudioDeviceType>()

        let renames = PriorityLogic.adoptStaleUIDs(
            connected: connected.map {
                PriorityLogic.ConnectedDevice(uid: $0.uid, name: $0.name, isInput: $0.type == .input, transport: $0.transportType)
            },
            known: known,
            inputOrder: order[.input] ?? [],
            outputOrder: order[.output] ?? []
        )
        for rename in renames {
            let type: AudioDeviceType = rename.isInput ? .input : .output
            NSLog("[AudioPriorityBar] %@ device changed UID: '%@' is now '%@'", type.rawValue, rename.oldUID, rename.newUID)

            if let index = known.firstIndex(where: { $0.uid == rename.oldUID && $0.isInput == rename.isInput }) {
                let old = known[index]
                known[index] = StoredDevice(uid: rename.newUID, name: old.name, isInput: old.isInput,
                                            lastSeen: old.lastSeen, transport: old.transport)
            }
            order[type] = (order[type] ?? []).map { $0 == rename.oldUID ? rename.newUID : $0 }
            if ignored[type]?.remove(rename.oldUID) != nil {
                ignored[type]?.insert(rename.newUID)
            }
            changedTypes.insert(type)
        }

        for type in AudioDeviceType.allCases {
            let connectedUIDs = Set(connected.filter { $0.type == type }.map(\.uid))

            // A device that just went away was last seen now, not at the previous refresh.
            for uid in (lastConnected[type] ?? []).subtracting(connectedUIDs) {
                if let index = known.firstIndex(where: { $0.uid == uid && $0.isInput == (type == .input) }) {
                    known[index].lastSeen = now
                }
            }
            lastConnected[type] = connectedUIDs

            if (order[type] ?? []).isEmpty, let current = currentDefaults[type], connectedUIDs.contains(current) {
                order[type] = [current]
                changedTypes.insert(type)
            }
        }

        for device in connected {
            let isInput = device.type == .input
            if let index = known.firstIndex(where: { $0.uid == device.uid && $0.isInput == isInput }) {
                known[index].name = device.name
                known[index].lastSeen = now
                known[index].transport = device.transportType
            } else {
                known.append(StoredDevice(uid: device.uid, name: device.name, isInput: isInput,
                                          lastSeen: now, transport: device.transportType))
            }
            if order[device.type]?.contains(device.uid) != true {
                order[device.type, default: []].append(device.uid)
                changedTypes.insert(device.type)
            }
        }

        saveDevices()
        for type in changedTypes {
            saveOrder(type)
            saveIgnored(type)
        }
    }

    func knownDevices(type: AudioDeviceType) -> [StoredDevice] {
        known.filter { $0.isInput == (type == .input) }
    }

    func storedDevice(uid: String, type: AudioDeviceType) -> StoredDevice? {
        known.first { $0.uid == uid && $0.isInput == (type == .input) }
    }

    /// Removes every trace of a device. It comes back as a new device if it reconnects.
    func forgetDevice(_ device: AudioDevice) {
        known.removeAll { $0.uid == device.uid && $0.isInput == (device.type == .input) }
        order[device.type]?.removeAll { $0 == device.uid }
        ignored[device.type]?.remove(device.uid)
        lastConnected[device.type]?.remove(device.uid)

        saveDevices()
        saveOrder(device.type)
        saveIgnored(device.type)
    }

    // MARK: - Priority order

    func sortByPriority(_ devices: [AudioDevice], type: AudioDeviceType) -> [AudioDevice] {
        var rank: [String: Int] = [:]
        for (index, uid) in (order[type] ?? []).enumerated() where rank[uid] == nil {
            rank[uid] = index
        }
        return devices.enumerated().sorted { a, b in
            let rankA = rank[a.element.uid] ?? Int.max
            let rankB = rank[b.element.uid] ?? Int.max
            return rankA != rankB ? rankA < rankB : a.offset < b.offset
        }.map(\.element)
    }

    /// Saves a new order for the devices currently shown, keeping every other device's rank.
    func saveVisibleOrder(_ devices: [AudioDevice], type: AudioDeviceType) {
        order[type] = PriorityLogic.mergeReorder(stored: order[type] ?? [], visibleNewOrder: devices.map(\.uid))
        saveOrder(type)
    }

    /// UID of the device that should be in use: the highest-ranked connected one that is not ignored.
    func targetUID(type: AudioDeviceType, connected: Set<String>) -> String? {
        PriorityLogic.pickTarget(ranked: order[type] ?? [], connected: connected, ignored: ignored[type] ?? [])
    }

    // MARK: - Ignored devices

    func isIgnored(_ device: AudioDevice) -> Bool {
        ignored[device.type]?.contains(device.uid) ?? false
    }

    func setIgnored(_ device: AudioDevice, _ isIgnored: Bool) {
        if isIgnored {
            ignored[device.type, default: []].insert(device.uid)
        } else {
            ignored[device.type]?.remove(device.uid)
        }
        saveIgnored(device.type)
    }

    // MARK: - Storage

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(known) {
            defaults.set(data, forKey: Key.devices)
        }
    }

    private func saveOrder(_ type: AudioDeviceType) {
        defaults.set(order[type] ?? [], forKey: type == .input ? Key.inputOrder : Key.outputOrder)
    }

    private func saveIgnored(_ type: AudioDeviceType) {
        defaults.set((ignored[type] ?? []).sorted(), forKey: type == .input ? Key.ignoredInputs : Key.ignoredOutputs)
    }

    private static func decodeDevices(_ data: Data?) -> [StoredDevice] {
        guard let data, let devices = try? JSONDecoder().decode([StoredDevice].self, from: data) else {
            return []
        }
        return devices
    }

    private static func readV1(_ defaults: UserDefaults) -> PriorityLogic.V1State {
        PriorityLogic.V1State(
            known: decodeDevices(defaults.data(forKey: V1Key.knownDevices)),
            inputPriorities: defaults.stringArray(forKey: V1Key.inputPriorities) ?? [],
            speakerPriorities: defaults.stringArray(forKey: V1Key.speakerPriorities) ?? [],
            headphonePriorities: defaults.stringArray(forKey: V1Key.headphonePriorities) ?? [],
            categories: defaults.dictionary(forKey: V1Key.deviceCategories) as? [String: String] ?? [:],
            hiddenMics: defaults.stringArray(forKey: V1Key.hiddenMics) ?? [],
            hiddenSpeakers: defaults.stringArray(forKey: V1Key.hiddenSpeakers) ?? [],
            hiddenHeadphones: defaults.stringArray(forKey: V1Key.hiddenHeadphones) ?? [],
            neverUse: defaults.stringArray(forKey: V1Key.neverUse) ?? [],
            customMode: defaults.bool(forKey: V1Key.customMode)
        )
    }
}
