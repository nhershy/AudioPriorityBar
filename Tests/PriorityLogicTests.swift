import Foundation

// Plain-swiftc tests for PriorityLogic. Run with Tests/run.sh.

private var failures = 0
private var checks = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL (line \(line)) \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private let usb: UInt32 = 0x7573_6220        // 'usb '
private let bluetooth: UInt32 = 0x626C_7565  // 'blue'
private let day: TimeInterval = 86400
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func stored(_ uid: String, _ name: String, input: Bool, daysAgo: Double = 0, transport: UInt32? = nil) -> StoredDevice {
    StoredDevice(uid: uid, name: name, isInput: input, lastSeen: now.addingTimeInterval(-daysAgo * day), transport: transport)
}

private func connected(_ uid: String, _ name: String, input: Bool, transport: UInt32 = usb) -> PriorityLogic.ConnectedDevice {
    PriorityLogic.ConnectedDevice(uid: uid, name: name, isInput: input, transport: transport)
}

private func isHeadphoneName(_ name: String) -> Bool {
    let lower = name.lowercased()
    return ["airpods", "earpods", "headphone"].contains { lower.contains($0) }
}

// MARK: - mergeReorder

private func testMergeReorder() {
    // B is disconnected, so only A and C are shown. Swapping them must leave B in slot 2.
    expectEqual(PriorityLogic.mergeReorder(stored: ["A", "B", "C"], visibleNewOrder: ["C", "A"]),
                ["C", "B", "A"], "hidden device keeps its slot")

    // The old behavior saved only the shown devices; nothing may be dropped.
    expectEqual(PriorityLogic.mergeReorder(stored: ["A", "B", "C", "D", "E"], visibleNewOrder: ["E", "A"]),
                ["E", "B", "C", "D", "A"], "no saved device is dropped")

    expectEqual(PriorityLogic.mergeReorder(stored: ["A", "B"], visibleNewOrder: ["B", "N", "A"]),
                ["B", "N", "A"], "device missing from the saved order is added")

    expectEqual(PriorityLogic.mergeReorder(stored: [], visibleNewOrder: ["A", "B"]),
                ["A", "B"], "empty saved order")

    expectEqual(PriorityLogic.mergeReorder(stored: ["A", "B", "A", "C"], visibleNewOrder: ["C", "A"]),
                ["C", "B", "A"], "duplicates in the saved order are collapsed")

    expectEqual(PriorityLogic.mergeReorder(stored: ["A", "B", "C"], visibleNewOrder: ["A", "B", "C"]),
                ["A", "B", "C"], "unchanged order stays unchanged")
}

// MARK: - pickTarget

private func testPickTarget() {
    expectEqual(PriorityLogic.pickTarget(ranked: ["A", "B", "C"], connected: ["B", "C"], ignored: []),
                "B", "skips disconnected")
    expectEqual(PriorityLogic.pickTarget(ranked: ["A", "B", "C"], connected: ["A", "B", "C"], ignored: ["A"]),
                "B", "skips ignored")
    expectEqual(PriorityLogic.pickTarget(ranked: ["A", "B"], connected: ["A"], ignored: ["A"]),
                nil, "nothing usable")
    expectEqual(PriorityLogic.pickTarget(ranked: [], connected: ["A"], ignored: []),
                nil, "unranked devices are never picked")
}

// MARK: - adoptStaleUIDs

private func testAdoptStaleUIDs() {
    typealias Rename = PriorityLogic.Rename

    // A USB mic moved to another port gets a new UID and takes over its old entry.
    expectEqual(
        PriorityLogic.adoptStaleUIDs(
            connected: [connected("mic:port2", "Clip Mic", input: true)],
            known: [stored("mic:port1", "Clip Mic", input: true)],
            inputOrder: ["mic:port1"], outputOrder: []),
        [Rename(oldUID: "mic:port1", newUID: "mic:port2", isInput: true)],
        "moved USB device adopts its old entry")

    // Two identical devices plugged in together are two devices, not one that was renamed.
    expectEqual(
        PriorityLogic.adoptStaleUIDs(
            connected: [connected("mic:port1", "Clip Mic", input: true),
                        connected("mic:port2", "Clip Mic", input: true)],
            known: [stored("mic:port1", "Clip Mic", input: true)],
            inputOrder: ["mic:port1"], outputOrder: []),
        [], "a connected same-name device is never taken over")

    expectEqual(
        PriorityLogic.adoptStaleUIDs(
            connected: [connected("mic:port1", "Clip Mic", input: true)],
            known: [stored("mic:port1", "Clip Mic", input: true), stored("mic:old", "Clip Mic", input: true)],
            inputOrder: [], outputOrder: []),
        [], "a device that is already known adopts nothing")

    expectEqual(
        PriorityLogic.adoptStaleUIDs(
            connected: [connected("x", "Combo", input: true)],
            known: [stored("y", "Combo", input: false)],
            inputOrder: [], outputOrder: ["y"]),
        [], "direction must match")

    // A second pair of same-named Bluetooth headphones is a different device.
    expectEqual(
        PriorityLogic.adoptStaleUIDs(
            connected: [connected("AA-BB:output", "AirPods Pro", input: false, transport: bluetooth)],
            known: [stored("CC-DD:output", "AirPods Pro", input: false)],
            inputOrder: [], outputOrder: ["CC-DD:output"]),
        [], "Bluetooth devices never adopt")

    expectEqual(
        PriorityLogic.adoptStaleUIDs(
            connected: [connected("usb-new", "AirPods Pro", input: false)],
            known: [stored("CC-DD:output", "AirPods Pro", input: false, transport: bluetooth)],
            inputOrder: [], outputOrder: ["CC-DD:output"]),
        [], "Bluetooth entries are never adopted")

    // Several stale entries with one name (AirPlay sessions): the ranked-highest one is reused.
    expectEqual(
        PriorityLogic.adoptStaleUIDs(
            connected: [connected("airplay-4", "AirPlay", input: false)],
            known: [stored("airplay-1", "AirPlay", input: false, daysAgo: 1),
                    stored("airplay-2", "AirPlay", input: false, daysAgo: 9),
                    stored("airplay-3", "AirPlay", input: false, daysAgo: 3)],
            inputOrder: [], outputOrder: ["speakers", "airplay-2", "airplay-1"]),
        [Rename(oldUID: "airplay-2", newUID: "airplay-4", isInput: false)],
        "highest-ranked stale entry wins")

    expectEqual(
        PriorityLogic.adoptStaleUIDs(
            connected: [connected("airplay-4", "AirPlay", input: false)],
            known: [stored("airplay-1", "AirPlay", input: false, daysAgo: 5),
                    stored("airplay-2", "AirPlay", input: false, daysAgo: 2)],
            inputOrder: [], outputOrder: []),
        [Rename(oldUID: "airplay-2", newUID: "airplay-4", isInput: false)],
        "unranked ties go to the most recently seen")

    // One device with a mic and an output shares a UID; each direction is renamed once,
    // and two new devices cannot both take the same old entry.
    expectEqual(
        PriorityLogic.adoptStaleUIDs(
            connected: [connected("combo:b", "Combo", input: true), connected("combo:b", "Combo", input: false),
                        connected("combo:c", "Combo", input: true)],
            known: [stored("combo:a", "Combo", input: true), stored("combo:a", "Combo", input: false)],
            inputOrder: ["combo:a"], outputOrder: ["combo:a"]),
        [Rename(oldUID: "combo:a", newUID: "combo:b", isInput: true),
         Rename(oldUID: "combo:a", newUID: "combo:b", isInput: false)],
        "each direction renamed once, each old entry adopted once")
}

// MARK: - migrateV1

private func testMigration() {
    // Same shape as real saved data from the old version, with made-up names and addresses.
    var v1 = PriorityLogic.V1State()
    v1.known = [
        stored("DISPLAY-1", "Wide Monitor", input: false, daysAgo: 20),
        stored("PHONE-MIC", "Phone Microphone", input: true, daysAgo: 30),
        stored("00-11-22-33-44-01:input", "Sam's AirPods Max", input: true, daysAgo: 4),
        stored("00-11-22-33-44-01:output", "Sam's AirPods Max", input: false, daysAgo: 4),
        stored("BuiltInMicrophoneDevice", "MacBook Pro Microphone", input: true),
        stored("BuiltInSpeakerDevice", "MacBook Pro Speakers", input: false),
        stored("WORK-PHONE-MIC", "Work Phone Microphone", input: true, daysAgo: 2),
        stored("00-11-22-33-44-02:input", "AirPods Pro", input: true, daysAgo: 1),
        stored("00-11-22-33-44-02:output", "AirPods Pro", input: false, daysAgo: 1),
        stored("airplay-1", "AirPlay", input: false, daysAgo: 40),
        // Mic with a headphone jack: one UID for both directions, stored as an output only.
        stored("USB:Desk Mic", "Desk Mic", input: false, daysAgo: 0.5),
        // The same UID stored twice.
        stored("DISPLAY-1", "Wide Monitor", input: false, daysAgo: 0.1),
        stored("USB:EarPods:1", "EarPods", input: false, daysAgo: 60),
        stored("USB:EarPods:2", "EarPods Microphone", input: true, daysAgo: 60),
    ]
    v1.inputPriorities = ["USB:Desk Mic", "BuiltInMicrophoneDevice"]
    v1.speakerPriorities = ["DISPLAY-1", "BuiltInSpeakerDevice"]
    v1.hiddenMics = ["LOOPBACK", "PHONE-MIC", "WORK-PHONE-MIC"]
    v1.hiddenSpeakers = ["LOOPBACK"]
    v1.neverUse = ["WORK-PHONE-MIC"]

    let v2 = PriorityLogic.migrateV1(v1, isHeadphoneName: isHeadphoneName)

    expectEqual(v2.outputOrder, [
        "00-11-22-33-44-02:output",   // headphones first, most recently seen first
        "00-11-22-33-44-01:output",
        "USB:EarPods:1",
        "DISPLAY-1",                  // then the saved speaker order
        "BuiltInSpeakerDevice",
        "USB:Desk Mic",               // then outputs that were never ranked
        "airplay-1",
    ], "output order")

    expectEqual(Array(v2.inputOrder.prefix(2)), ["USB:Desk Mic", "BuiltInMicrophoneDevice"],
                "saved mic order stays on top")
    expectEqual(Set(v2.inputOrder), Set(v2.known.filter(\.isInput).map(\.uid)),
                "every known mic is ranked")
    expectEqual(v2.inputOrder.count, 7, "no duplicate mics")

    expectEqual(v2.known.filter { $0.uid == "DISPLAY-1" }.count, 1, "duplicate known entry collapsed")
    expectEqual(v2.known.first { $0.uid == "DISPLAY-1" }?.lastSeen, now.addingTimeInterval(-0.1 * day),
                "the most recent sighting is kept")
    expectEqual(v2.known.filter { $0.uid == "USB:Desk Mic" }.map(\.isInput).sorted { !$0 && $1 }, [false, true],
                "mic+output device is known in both directions")

    expectEqual(v2.ignoredInputs, ["LOOPBACK", "PHONE-MIC", "WORK-PHONE-MIC"], "ignored mics")
    expectEqual(v2.ignoredOutputs, ["LOOPBACK", "WORK-PHONE-MIC"], "ignored outputs")
    expectEqual(v2.autoSwitchEnabled, true, "auto stays on")

    // Hand-set categories and per-category hiding.
    var custom = PriorityLogic.V1State()
    custom.known = [
        stored("spk", "Desk Speakers", input: false, daysAgo: 1),
        stored("amp", "Headphone Amp", input: false, daysAgo: 2),
        stored("cans", "Studio Cans", input: false, daysAgo: 3),
        stored("buds", "AirPods", input: false, daysAgo: 4),
    ]
    custom.categories = ["amp": "speaker", "cans": "headphone"]
    custom.headphonePriorities = ["buds", "cans", "amp"]   // "amp" was moved out afterwards
    custom.speakerPriorities = ["amp", "spk", "cans"]      // "cans" was moved out afterwards
    custom.hiddenHeadphones = ["spk", "buds"]              // "spk" is a speaker, so it was still in use
    custom.hiddenSpeakers = ["amp"]
    custom.customMode = true

    let migrated = PriorityLogic.migrateV1(custom, isHeadphoneName: isHeadphoneName)
    expectEqual(migrated.outputOrder, ["buds", "cans", "amp", "spk"], "categories set by hand are respected")
    expectEqual(migrated.ignoredOutputs, ["amp", "buds"], "only hiding in the device's own category counts")
    expectEqual(migrated.autoSwitchEnabled, false, "manual mode becomes auto off")

    expectEqual(PriorityLogic.migrateV1(PriorityLogic.V1State(), isHeadphoneName: isHeadphoneName),
                PriorityLogic.V2State(), "fresh install")
}

// MARK: - StoredDevice

private func testStoredDeviceDecoding() {
    // Data written by the old version has no "transport" field.
    let old = #"[{"uid":"a","name":"Mic","isInput":true,"lastSeen":700000000}]"#
    let decoded = try? JSONDecoder().decode([StoredDevice].self, from: Data(old.utf8))
    expectEqual(decoded?.first?.uid, "a", "old known-device data still decodes")
    expectEqual(decoded?.first?.transport, nil, "missing transport decodes as nil")
}

@main
enum PriorityLogicTests {
    static func main() {
        testMergeReorder()
        testPickTarget()
        testAdoptStaleUIDs()
        testMigration()
        testStoredDeviceDecoding()

        if failures > 0 {
            print("\(failures) of \(checks) checks failed")
            exit(1)
        }
        print("All \(checks) checks passed")
    }
}
