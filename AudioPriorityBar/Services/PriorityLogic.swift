import Foundation

/// A device the app has seen at least once, remembered across launches.
/// A physical device with both a microphone and an output is stored twice, once per direction.
struct StoredDevice: Codable, Equatable {
    let uid: String
    var name: String
    let isInput: Bool
    var lastSeen: Date
    /// CoreAudio transport type, kept so a disconnected device still gets the right icon.
    var transport: UInt32?

    var lastSeenRelative: String {
        let interval = Date().timeIntervalSince(lastSeen)

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else if interval < 604800 {
            return "\(Int(interval / 86400))d ago"
        } else if interval < 2592000 {
            return "\(Int(interval / 604800))w ago"
        } else {
            return "\(Int(interval / 2592000))mo ago"
        }
    }
}

/// The decisions the app makes about priorities, kept free of CoreAudio and UserDefaults
/// so they can be tested without hardware (see Tests/run.sh).
enum PriorityLogic {

    // MARK: - Reordering

    /// Applies a reorder of the devices currently shown to the full saved order.
    ///
    /// The shown devices take, in their new order, the slots shown devices already occupied.
    /// Devices that are not shown (disconnected or ignored) keep their position, so a reorder
    /// can never drop them from the saved order.
    static func mergeReorder(stored: [String], visibleNewOrder: [String]) -> [String] {
        let visible = Set(visibleNewOrder)
        var remaining = visibleNewOrder.makeIterator()
        var result: [String] = []

        for uid in stored {
            if visible.contains(uid) {
                if let next = remaining.next() {
                    result.append(next)
                }
            } else {
                result.append(uid)
            }
        }
        while let next = remaining.next() {
            result.append(next)
        }

        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    // MARK: - Choosing the device to use

    /// The highest-ranked device that is connected and not ignored.
    static func pickTarget(ranked: [String], connected: Set<String>, ignored: Set<String>) -> String? {
        ranked.first { connected.contains($0) && !ignored.contains($0) }
    }

    // MARK: - Devices whose UID changed

    struct ConnectedDevice: Equatable {
        let uid: String
        let name: String
        let isInput: Bool
        let transport: UInt32
    }

    struct Rename: Equatable {
        let oldUID: String
        let newUID: String
        let isInput: Bool
    }

    /// 'blue' and 'blea'. Bluetooth UIDs are built from the hardware address, so a new
    /// Bluetooth UID is always a different physical device, never a renamed one.
    static let bluetoothTransports: Set<UInt32> = [0x626C_7565, 0x626C_6561]

    /// Finds connected devices that are really a known device under a new UID.
    ///
    /// Some devices get a different UID over time: USB devices without a serial number embed
    /// the port they are plugged into, and AirPlay targets get a UID per session. A connected
    /// device with an unknown UID takes over a remembered entry when that entry has the same
    /// name and direction and is not connected itself. With several such entries, the
    /// highest-ranked one wins, then the most recently seen.
    static func adoptStaleUIDs(
        connected: [ConnectedDevice],
        known: [StoredDevice],
        inputOrder: [String],
        outputOrder: [String]
    ) -> [Rename] {
        func key(_ uid: String, _ isInput: Bool) -> String { (isInput ? "in|" : "out|") + uid }

        let connectedKeys = Set(connected.map { key($0.uid, $0.isInput) })
        let knownKeys = Set(known.map { key($0.uid, $0.isInput) })
        var adopted = Set<String>()
        var renames: [Rename] = []

        for device in connected {
            guard !bluetoothTransports.contains(device.transport),
                  !knownKeys.contains(key(device.uid, device.isInput)) else { continue }

            let order = device.isInput ? inputOrder : outputOrder
            let candidates = known.filter { stored in
                stored.isInput == device.isInput
                    && stored.name == device.name
                    && !bluetoothTransports.contains(stored.transport ?? 0)
                    && !connectedKeys.contains(key(stored.uid, stored.isInput))
                    && !adopted.contains(key(stored.uid, stored.isInput))
            }
            let best = candidates.min { a, b in
                let rankA = order.firstIndex(of: a.uid) ?? Int.max
                let rankB = order.firstIndex(of: b.uid) ?? Int.max
                if rankA != rankB { return rankA < rankB }
                return a.lastSeen > b.lastSeen
            }
            guard let best else { continue }

            adopted.insert(key(best.uid, best.isInput))
            renames.append(Rename(oldUID: best.uid, newUID: device.uid, isInput: device.isInput))
        }
        return renames
    }

    // MARK: - Migration from the Speakers / Headphones / Manual model

    /// Everything the first version of the app stored.
    struct V1State {
        var known: [StoredDevice] = []
        var inputPriorities: [String] = []
        var speakerPriorities: [String] = []
        var headphonePriorities: [String] = []
        /// UID to "speaker" or "headphone", only for devices the user moved by hand.
        var categories: [String: String] = [:]
        var hiddenMics: [String] = []
        var hiddenSpeakers: [String] = []
        var hiddenHeadphones: [String] = []
        var neverUse: [String] = []
        var customMode = false
    }

    struct V2State: Equatable {
        var known: [StoredDevice] = []
        var inputOrder: [String] = []
        var outputOrder: [String] = []
        var ignoredInputs: [String] = []
        var ignoredOutputs: [String] = []
        var autoSwitchEnabled = true
    }

    /// Builds the single-list model from the old one.
    ///
    /// Outputs: headphones first (they used to win as soon as one connected), then speakers,
    /// each in their saved order followed by devices that were never ranked, newest first.
    static func migrateV1(_ v1: V1State, isHeadphoneName: (String) -> Bool) -> V2State {
        // The old store could hold the same device twice; keep the most recent sighting.
        var known: [StoredDevice] = []
        for device in v1.known {
            if let index = known.firstIndex(where: { $0.uid == device.uid && $0.isInput == device.isInput }) {
                if device.lastSeen > known[index].lastSeen {
                    known[index] = device
                }
            } else {
                known.append(device)
            }
        }

        // The old store was keyed by UID alone, so a device with both a microphone and an
        // output was remembered in one direction only. Recreate the other half wherever an
        // old list shows it existed.
        func ensureKnown(_ uid: String, isInput: Bool) {
            guard !known.contains(where: { $0.uid == uid && $0.isInput == isInput }),
                  let twin = known.first(where: { $0.uid == uid }) else { return }
            known.append(StoredDevice(uid: uid, name: twin.name, isInput: isInput,
                                      lastSeen: twin.lastSeen, transport: twin.transport))
        }
        for uid in v1.inputPriorities + v1.hiddenMics {
            ensureKnown(uid, isInput: true)
        }
        for uid in v1.speakerPriorities + v1.headphonePriorities + v1.hiddenSpeakers + v1.hiddenHeadphones {
            ensureKnown(uid, isInput: false)
        }

        let knownInputs = known.filter { $0.isInput }
        let knownOutputs = known.filter { !$0.isInput }
        let inputUIDs = Set(knownInputs.map(\.uid))
        let outputUIDs = Set(knownOutputs.map(\.uid))

        func isHeadphone(_ device: StoredDevice) -> Bool {
            if let category = v1.categories[device.uid] {
                return category == "headphone"
            }
            return isHeadphoneName(device.name)
        }
        let headphoneUIDs = Set(knownOutputs.filter(isHeadphone).map(\.uid))
        let outputsByRecency = knownOutputs.sorted { $0.lastSeen > $1.lastSeen }.map(\.uid)

        var outputOrder: [String] = []
        func appendOutputs(_ uids: [String]) {
            for uid in uids where outputUIDs.contains(uid) && !outputOrder.contains(uid) {
                outputOrder.append(uid)
            }
        }
        appendOutputs(v1.headphonePriorities.filter { headphoneUIDs.contains($0) })
        appendOutputs(outputsByRecency.filter { headphoneUIDs.contains($0) })
        appendOutputs(v1.speakerPriorities.filter { !headphoneUIDs.contains($0) })
        appendOutputs(outputsByRecency)

        var inputOrder: [String] = []
        let inputsByRecency = knownInputs.sorted { $0.lastSeen > $1.lastSeen }.map(\.uid)
        for uid in v1.inputPriorities + inputsByRecency where inputUIDs.contains(uid) && !inputOrder.contains(uid) {
            inputOrder.append(uid)
        }

        // "Hidden" and "never use" both become "ignored". Old hidden lists were per category;
        // a device hidden only in the category it was not in was still in use, so it stays.
        var ignoredInputs: [String] = []
        for uid in v1.hiddenMics + v1.neverUse where !ignoredInputs.contains(uid) {
            ignoredInputs.append(uid)
        }
        var ignoredOutputs: [String] = []
        for uid in v1.hiddenSpeakers + v1.hiddenHeadphones + v1.neverUse where !ignoredOutputs.contains(uid) {
            let wasHidden: Bool
            if v1.neverUse.contains(uid) || !outputUIDs.contains(uid) {
                wasHidden = true
            } else if headphoneUIDs.contains(uid) {
                wasHidden = v1.hiddenHeadphones.contains(uid)
            } else {
                wasHidden = v1.hiddenSpeakers.contains(uid)
            }
            if wasHidden {
                ignoredOutputs.append(uid)
            }
        }

        return V2State(
            known: known,
            inputOrder: inputOrder,
            outputOrder: outputOrder,
            ignoredInputs: ignoredInputs,
            ignoredOutputs: ignoredOutputs,
            autoSwitchEnabled: !v1.customMode
        )
    }
}
