import Foundation
import IOKit.hid

/// One Logitech keyboard or mouse spoken to over HID++ 2.0 (Bluetooth: device index 0xFF, long
/// reports 0x11 on the device's own HID interface). Finds the features, lists the controls that
/// can be taken over, diverts the ones that have an action (their presses then come here instead
/// of doing their own thing) and reads/writes SmartShift.
///
/// The device forgets diversions when it reconnects or sleeps; `DeviceManager` sets it up again
/// on every connect and after the Mac wakes.
@MainActor
final class LogiDevice: ObservableObject, Identifiable {
    enum State: Equatable {
        case probing, ready, notHIDPP
    }

    enum Event {
        case down(UInt16), up(UInt16), move(dx: Int, dy: Int)
    }

    nonisolated let id: String
    let hid: IOHIDDevice
    let name: String
    let productID: Int
    let serial: String
    /// The same physical device may show up as several HID interfaces; only one answers HID++.
    var identity: String { "\(productID)-\(serial)" }

    @Published private(set) var state: State = .probing
    @Published private(set) var controls: [ReprogControls.Control] = []
    @Published private(set) var smartShift: SmartShift.State?
    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    /// Keyboard backlight settings (BACKLIGHT2), nil when the device has none.
    @Published private(set) var backlight: BacklightConfig?

    var onEvent: ((Event) -> Void)?
    /// An HID++ message came on an interface that did not answer the ping: after a wake the
    /// keyboard answers only some seconds later, so it is worth setting up again.
    var onAlive: (() -> Void)?

    /// Input reports seen, all and HID++ only (logged once a minute by DeviceManager).
    static var reportCount = 0
    static var hidppReportCount = 0

    private var features: [UInt16: UInt8] = [:]
    /// Diverted controls → raw XY on.
    private var diverted: [UInt16: Bool] = [:]
    private var pressed: Set<UInt16> = []
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    private struct Pending {
        let sequence: Int
        let featureIndex: UInt8
        let function: UInt8
        let continuation: CheckedContinuation<HIDPP.Message?, Never>
    }
    private var pending: Pending?
    private var sequence = 0
    /// One request at a time: answers are matched by feature index and function.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(hid: IOHIDDevice) {
        self.hid = hid
        name = IOHIDDeviceGetProperty(hid, kIOHIDProductKey as CFString) as? String ?? "Logitech"
        productID = IOHIDDeviceGetProperty(hid, kIOHIDProductIDKey as CFString) as? Int ?? 0
        serial = IOHIDDeviceGetProperty(hid, kIOHIDSerialNumberKey as CFString) as? String
            ?? String(IOHIDDeviceGetProperty(hid, kIOHIDLocationIDKey as CFString) as? Int ?? 0)
        id = "\(Unmanaged.passUnretained(hid).toOpaque())"
        buffer.initialize(repeating: 0, count: 64)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(hid, buffer, 64, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            // Every mouse movement and key press comes here too (~98 % of the reports, ~40 a
            // second while the mouse moves); only HID++ long reports matter, so the rest is dropped
            // before anything is copied.
            let isHIDPP = reportID == UInt32(HIDPP.longReportID) || (length > 0 && report[0] == HIDPP.longReportID)
            MainActor.assumeIsolated { LogiDevice.reportCount += 1 }
            guard isHIDPP else { return }
            let device = Unmanaged<LogiDevice>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // Some interfaces deliver the report without its ID byte.
            if bytes.first != HIDPP.longReportID { bytes.insert(HIDPP.longReportID, at: 0) }
            MainActor.assumeIsolated {
                LogiDevice.hidppReportCount += 1
                device.received(bytes)
            }
        }, context)
    }

    /// Before the object goes: stops callbacks into it.
    func detach() {
        IOHIDDeviceRegisterInputReportCallback(hid, buffer, 64, nil, nil)
        pending?.continuation.resume(returning: nil)
        pending = nil
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        onEvent = nil
        onAlive = nil
    }

    var isMouse: Bool { controls.contains { ReprogControls.Flags(rawValue: $0.flags).contains(.mouse) } || smartShift != nil }
    /// Physical controls that can be taken over (virtual ones are Logi Options+ bookkeeping).
    var divertable: [ReprogControls.Control] {
        controls.filter { $0.isDivertable && !$0.isVirtual && $0.cid != KnownControl.virtualGesture }
    }

    // MARK: - Setup

    /// Ping, then features, controls and SmartShift. Returns false when the interface does not speak HID++.
    func setUp() async -> Bool {
        state = .probing
        features.removeAll()
        diverted.removeAll()
        pressed.removeAll()
        guard let ping = await send(featureIndex: 0, function: 1, params: [0, 0, 0x5A]), !ping.isError else {
            state = .notHIDPP
            return false
        }
        Log.info("\(name) (\(String(format: "0x%04X", productID))): HID++ \(ping.params[0]).\(ping.params[1])", "hidpp")
        for feature in [HIDPP.Feature.reprogControls, .smartShiftEnhanced, .smartShift, .battery] {
            if let index = await featureIndex(feature.rawValue) { features[feature.rawValue] = index }
        }
        // Gone again during setup (all requests failed): not ready.
        guard !features.isEmpty else {
            state = .notHIDPP
            return false
        }
        Log.info("\(name): features \(features.map { String(format: "%04X@%d", $0.key, $0.value) }.sorted())", "hidpp")
        await listAllFeatures()

        if let reprog = features[HIDPP.Feature.reprogControls.rawValue],
           let count = await send(featureIndex: reprog, function: ReprogControls.getCount)?.params.first {
            var list: [ReprogControls.Control] = []
            for index in 0..<count {
                if let info = await send(featureIndex: reprog, function: ReprogControls.getCidInfo, params: [index]), !info.isError {
                    list.append(ReprogControls.control(from: info.params))
                }
            }
            Log.info("\(name): controls " + list.map { String(format: "%04X/%03X", $0.cid, $0.flags) }.joined(separator: " "), "hidpp")
            // Gone in the middle of the list (a reconnect): a short list would leave keys
            // like F9 untaken until the next connect, so set up again instead.
            guard list.count == Int(count) else {
                Log.warning("\(name): read \(list.count) of \(count) controls, setting up again", "hidpp")
                state = .notHIDPP
                return false
            }
            controls = list
        }
        smartShift = await readSmartShift()
        if let smartShift { Log.info("\(name): SmartShift mode \(smartShift.mode) threshold \(smartShift.threshold)", "hidpp") }
        state = .ready
        await refreshBattery()
        await refreshBacklight()
        return true
    }

    /// Every feature the device has (FEATURE_SET 0x0001), index → ID: names the device's own
    /// messages in the journal and shows what it can do (backlight control 0x1982, …).
    private(set) var allFeatures: [UInt8: UInt16] = [:]

    private func listAllFeatures() async {
        guard let index = await featureIndex(HIDPP.Feature.featureSet.rawValue),
              let count = await send(featureIndex: index, function: 0)?.params.first else { return }
        var result: [UInt8: UInt16] = [0: 0x0000]
        for i in 1...max(count, 1) {
            if let answer = await send(featureIndex: index, function: 1, params: [i]), !answer.isError {
                result[i] = HIDPP.uint16(answer.params, at: 0)
            }
        }
        allFeatures = result
        Log.info("\(name): all features " + result.sorted { $0.key < $1.key }.map { String(format: "%d=%04X", $0.key, $0.value) }.joined(separator: " "), "hidpp")
    }

    private func featureIndex(_ feature: UInt16) async -> UInt8? {
        guard let answer = await send(featureIndex: 0, function: 0, params: HIDPP.bytes(feature)),
              !answer.isError, let index = answer.params.first, index != 0 else { return nil }
        return index
    }

    // MARK: - Diversion

    /// Diverts exactly `wanted` (control → raw XY), undiverts the rest that MXCtl diverted.
    /// Returns false when a request got no answer (worth trying again).
    @discardableResult
    func divert(_ wanted: [UInt16: Bool]) async -> Bool {
        guard state == .ready, let reprog = features[HIDPP.Feature.reprogControls.rawValue] else { return true }
        var allTaken = true
        for (cid, rawXY) in wanted where diverted[cid] != rawXY {
            let answer = await send(featureIndex: reprog, function: ReprogControls.setCidReporting,
                                    params: ReprogControls.reportingParams(cid: cid, divert: true, rawXY: rawXY))
            if let answer, !answer.isError {
                diverted[cid] = rawXY
                Log.info("\(name): \(KnownControl.name(cid)) taken over\(rawXY ? " with movement" : "")", "hidpp")
            } else {
                if answer == nil { allTaken = false }
                Log.warning("\(name): cannot take over \(String(format: "0x%04X", cid)) (error \(answer?.errorCode ?? 0))", "hidpp")
            }
        }
        for cid in diverted.keys where wanted[cid] == nil {
            _ = await send(featureIndex: reprog, function: ReprogControls.setCidReporting,
                           params: ReprogControls.reportingParams(cid: cid, divert: false, rawXY: false))
            diverted[cid] = nil
            Log.info("\(name): \(KnownControl.name(cid)) given back", "hidpp")
        }
        return allTaken
    }

    /// At quit: gives every key back to the device at once, without waiting for answers.
    func releaseAllNow() {
        guard let reprog = features[HIDPP.Feature.reprogControls.rawValue] else { return }
        for cid in diverted.keys {
            write(HIDPP.request(featureIndex: reprog, function: ReprogControls.setCidReporting,
                                params: ReprogControls.reportingParams(cid: cid, divert: false, rawXY: false)))
        }
        diverted.removeAll()
    }

    // MARK: - SmartShift

    private var smartShiftFeature: (index: UInt8, enhanced: Bool)? {
        if let index = features[HIDPP.Feature.smartShiftEnhanced.rawValue] { return (index, true) }
        if let index = features[HIDPP.Feature.smartShift.rawValue] { return (index, false) }
        return nil
    }

    private func readSmartShift() async -> SmartShift.State? {
        guard let feature = smartShiftFeature,
              let answer = await send(featureIndex: feature.index, function: SmartShift.readFunction(enhanced: feature.enhanced)),
              !answer.isError else { return nil }
        return SmartShift.state(from: answer.params)
    }

    func writeSmartShift(threshold: Int) async {
        guard state == .ready, let feature = smartShiftFeature else { return }
        let value = SmartShift.State(mode: .keep, threshold: UInt8(min(max(threshold, 1), 255)))
        let answer = await send(featureIndex: feature.index, function: SmartShift.writeFunction(enhanced: feature.enhanced),
                                params: SmartShift.params(value))
        if let answer, !answer.isError {
            smartShift = await readSmartShift()
            Log.info("\(name): SmartShift threshold → \(threshold), now \(String(describing: smartShift))", "hidpp")
        } else {
            Log.warning("\(name): SmartShift write failed (error \(answer?.errorCode ?? 0))", "hidpp")
        }
    }

    // MARK: - Battery (UNIFIED_BATTERY 0x1004, function 1: percentage, level, external power)

    private func readBattery() async -> (percent: Int, charging: Bool)? {
        guard let index = features[HIDPP.Feature.battery.rawValue],
              let answer = await send(featureIndex: index, function: 1), !answer.isError,
              answer.params.count >= 3 else { return nil }
        return (Int(answer.params[0]), answer.params[2] != 0)
    }

    func refreshBattery() async {
        guard state == .ready, let status = await readBattery() else { return }
        if status.percent != battery || status.charging != charging {
            Log.info("\(name): battery \(status.percent)%\(status.charging ? ", charging" : "")", "battery")
        }
        apply(percent: status.percent, charging: status.charging)
    }

    private func apply(percent: Int, charging isCharging: Bool) {
        battery = percent
        charging = isCharging
        EventJournal.shared.recordBattery(device: name, percent: percent, charging: isCharging)
        BatteryAlerts.check(device: name, identity: identity, percent: percent, charging: isCharging)
    }

    // MARK: - Backlight (BACKLIGHT2 0x1982)

    private var backlightIndex: UInt8? { allFeatures.first { $0.value == 0x1982 }?.key }

    /// Reads the backlight settings; a change goes to the journal.
    func refreshBacklight(reason: String? = nil) async {
        guard state == .ready, let index = backlightIndex,
              let answer = await send(featureIndex: index, function: BacklightConfig.readFunction), !answer.isError,
              let config = BacklightConfig(params: answer.params) else { return }
        if config != backlight {
            Log.info("\(name): backlight \(config.summary)", "backlight")
            EventJournal.shared.recordBacklight(device: name, config: config, reason: reason)
        }
        backlight = config
    }

    /// Switches the backlight on or off, keeping its mode, level and timings.
    @discardableResult
    func setBacklight(enabled: Bool, reason: String) async -> Bool {
        guard state == .ready, let index = backlightIndex else { return false }
        if backlight == nil { await refreshBacklight() }
        guard var config = backlight else { return false }
        config.enabled = enabled
        let answer = await send(featureIndex: index, function: BacklightConfig.writeFunction, params: config.writeParams)
        guard let answer, !answer.isError else {
            Log.warning("\(name): backlight \(enabled ? "on" : "off") failed (error \(answer?.errorCode ?? 0))", "backlight")
            return false
        }
        await refreshBacklight(reason: reason)
        return true
    }

    var hasBacklight: Bool { backlightIndex != nil }

    // MARK: - I/O

    private func send(featureIndex: UInt8, function: UInt8, params: [UInt8] = []) async -> HIDPP.Message? {
        await acquire()
        defer { release() }
        let report = HIDPP.request(featureIndex: featureIndex, function: function, params: params)
        sequence += 1
        let sequence = sequence
        return await withCheckedContinuation { continuation in
            pending = Pending(sequence: sequence, featureIndex: featureIndex, function: function, continuation: continuation)
            guard write(report) else {
                pending = nil
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let pending = self.pending, pending.sequence == sequence else { return }
                    self.pending = nil
                    pending.continuation.resume(returning: nil)
                }
            }
        }
    }

    @discardableResult
    private func write(_ report: [UInt8]) -> Bool {
        let result = report.withUnsafeBufferPointer { pointer in
            IOHIDDeviceSetReport(hid, kIOHIDReportTypeOutput, CFIndex(report[0]), pointer.baseAddress!, pointer.count)
        }
        if result != kIOReturnSuccess, state != .probing {
            Log.warning("\(name): write failed \(String(format: "0x%08X", result))", "hidpp")
        }
        return result == kIOReturnSuccess
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func received(_ report: [UInt8]) {
        guard let message = HIDPP.parse(report) else { return }
        if state == .notHIDPP {
            state = .probing
            onAlive?()
            return
        }
        if message.softwareID == HIDPP.softwareID, let pending {
            let matches = message.isError
                ? message.params.first == pending.featureIndex && message.function == pending.function
                : message.featureIndex == pending.featureIndex && message.function == pending.function
            if matches {
                self.pending = nil
                pending.continuation.resume(returning: message)
            }
            return
        }
        guard message.softwareID == 0 else { return }
        // UNIFIED_BATTERY announces changes itself (same layout as getStatus): no need to wait for the poll.
        if message.featureIndex == features[HIDPP.Feature.battery.rawValue], message.params.count >= 3 {
            let percent = Int(message.params[0]), isCharging = message.params[2] != 0
            if percent != battery || isCharging != charging {
                Log.info("\(name): battery \(percent)%\(isCharging ? ", charging" : "") (reported by the device)", "battery")
            }
            apply(percent: percent, charging: isCharging)
            return
        }
        guard let reprog = features[HIDPP.Feature.reprogControls.rawValue], message.featureIndex == reprog else {
            // Anything else the device says by itself (backlight, …) goes to the journal to learn from.
            let feature = allFeatures[message.featureIndex].map { String(format: "%04X", $0) } ?? "index \(message.featureIndex)"
            let detail = "feature \(feature) event \(message.function): " + message.params.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            Log.debug("\(name): \(detail)", "hidpp")
            EventJournal.shared.record(JournalEvent(time: Date(), kind: .deviceMessage, device: name, detail: detail))
            return
        }
        switch message.function {
        case ReprogControls.buttonsEvent:
            let now = ReprogControls.pressedControls(from: message.params)
            for cid in now.subtracting(pressed) { onEvent?(.down(cid)) }
            for cid in pressed.subtracting(now) { onEvent?(.up(cid)) }
            pressed = now
        case ReprogControls.rawXYEvent:
            let move = ReprogControls.rawXY(from: message.params)
            onEvent?(.move(dx: move.dx, dy: move.dy))
        default:
            break
        }
    }
}
