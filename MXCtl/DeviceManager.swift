import AppKit
import Combine
import IOKit.hid

/// Finds Logitech devices (vendor 0x046D), sets each up over HID++, keeps the diversions in line
/// with the config and turns presses, holds and swipes into actions.
@MainActor
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()
    static let logitechVendorID = 0x046D

    /// Set up and answering HID++, one per physical device.
    @Published private(set) var devices: [LogiDevice] = []
    /// "Определить клавишу": every key that can be taken over is, until one is pressed.
    @Published private(set) var isLearning = false
    @Published private(set) var learned: (device: String, cid: UInt16)?

    private var manager: IOHIDManager?
    private var all: [IOHIDDevice: LogiDevice] = [:]
    private var gesture = GestureTracker(threshold: 60)
    private var gestureControl: UInt16?
    private var gestureTrace = GestureTrace()
    private var gestureStart: UInt64 = 0
    private var learnTimeout: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var batteryTimer: Timer?
    private var reportTimer: Timer?

    private var config: Config { ConfigStore.shared.config }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.logitechVendorID] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let manager = Unmanaged<DeviceManager>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { manager.added(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let manager = Unmanaged<DeviceManager>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { manager.removed(device) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.info("HID manager opened: \(result == kIOReturnSuccess ? "ok" : String(format: "0x%08X", result))", "devices")
        self.manager = manager

        // Bindings and SmartShift follow the config.
        ConfigStore.shared.$config
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applyAll() }
            .store(in: &cancellables)

        // The devices forget diversions over a Mac sleep.
        // Backlight off while the Mac sleeps or its screens are off, back on at wake.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.macSleeps(notification.name == NSWorkspace.willSleepNotification ? "Mac уснул" : "экран погас") }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.macWakes() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.info("Mac woke up, setting devices up again", "devices")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.setUpAgain() }
            }
        }
        reportTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard LogiDevice.reportCount > 0 else { return }
                Log.debug("HID reports in the last minute: \(LogiDevice.reportCount), HID++ \(LogiDevice.hidppReportCount)", "devices")
                LogiDevice.reportCount = 0
                LogiDevice.hidppReportCount = 0
            }
        }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for device in self.devices {
                    Task {
                        await device.refreshBattery()
                        await device.refreshBacklight()
                    }
                }
            }
        }
    }

    /// Input Monitoring granted later: open again so the devices come in.
    func restart() {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        for device in all.values { device.detach() }
        all.removeAll()
        devices.removeAll()
        manager = nil
        cancellables.removeAll()
        batteryTimer?.invalidate()
        reportTimer?.invalidate()
        start()
    }

    func setUpAgain() {
        retries.removeAll()
        for device in all.values {
            Task { await setUp(device) }
        }
    }

    // MARK: - Backlight off while asleep

    private var macAsleep = false
    private static let backlightOffKey = "backlightOffForSleep"
    /// Devices whose backlight MXCtl switched off for the night; kept across restarts so a
    /// backlight is never left off by MXCtl.
    private var backlightOffForSleep: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.backlightOffKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.backlightOffKey) }
    }

    private func macSleeps(_ reason: String) {
        guard !macAsleep else { return }
        macAsleep = true
        guard config.backlightOffOnSleep else { return }
        for device in devices where device.hasBacklight && device.backlight?.enabled == true {
            // Remembered before writing: a keyboard going to sleep may apply the write and not
            // answer, and a backlight switched off that way was never switched back on.
            backlightOffForSleep.insert(device.identity)
            Task {
                if await device.setBacklight(enabled: false, reason: reason) {
                    Log.info("\(device.name): backlight off (\(reason))", "backlight")
                }
            }
        }
    }

    private func macWakes() {
        guard macAsleep else { return }
        macAsleep = false
        for device in devices { restoreBacklight(device) }
    }

    /// Back on if MXCtl switched it off; a keyboard that reconnects after the wake gets it at setup.
    private func restoreBacklight(_ device: LogiDevice) {
        guard !macAsleep, backlightOffForSleep.contains(device.identity) else { return }
        Task {
            if await device.setBacklight(enabled: true, reason: "Mac проснулся") {
                backlightOffForSleep.remove(device.identity)
                Log.info("\(device.name): backlight back on", "backlight")
            }
        }
    }

    func releaseAll() {
        for device in devices { device.releaseAllNow() }
    }

    // MARK: - Devices coming and going

    private func added(_ hid: IOHIDDevice) {
        guard all[hid] == nil else { return }
        let device = LogiDevice(hid: hid)
        all[hid] = device
        let page = IOHIDDeviceGetProperty(hid, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(hid, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        Log.debug("HID interface: \(device.name) \(String(format: "0x%04X", device.productID)), usage \(String(format: "0x%X/0x%X", page, usage))", "devices")
        device.onAlive = { [weak self, weak device] in
            guard let self, let device else { return }
            Log.info("\(device.name): HID++ message on an interface that did not answer, setting up again", "devices")
            Task { await self.setUp(device) }
        }
        Task { await setUp(device) }
    }

    private func removed(_ hid: IOHIDDevice) {
        guard let device = all.removeValue(forKey: hid) else { return }
        device.detach()
        retries[device.id] = nil
        if devices.contains(where: { $0 === device }) {
            devices.removeAll { $0 === device }
            Log.info("\(device.name) disconnected", "devices")
            EventJournal.shared.record(JournalEvent(time: Date(), kind: .disconnected, device: device.name))
        }
        if gestureControl != nil { gestureControl = nil }
    }

    /// Setups under way (by device id) and ones asked for meanwhile: a connect and the wake
    /// both set up the same interface, and two setups at once break each other's requests.
    private var settingUp: Set<String> = []
    private var setUpAsked: Set<String> = []
    /// Retries for an interface that did not answer the ping (the keyboard after a wake).
    private var retries: [String: Int] = [:]
    private static let retryDelays: [Double] = [3, 10, 30, 60]

    private func setUp(_ device: LogiDevice) async {
        guard !settingUp.contains(device.id) else {
            setUpAsked.insert(device.id)
            return
        }
        settingUp.insert(device.id)
        await setUpOnce(device)
        settingUp.remove(device.id)
        if setUpAsked.remove(device.id) != nil, isPresent(device) { await setUp(device) }
    }

    private func isPresent(_ device: LogiDevice) -> Bool { all.values.contains { $0 === device } }

    private func setUpOnce(_ device: LogiDevice) async {
        // Another interface of the same device already speaks HID++.
        if devices.contains(where: { $0 !== device && $0.identity == device.identity }) { return }
        guard await device.setUp() else {
            let attempt = retries[device.id, default: 0]
            guard attempt < Self.retryDelays.count else {
                Log.debug("\(device.name): this interface does not answer HID++", "devices")
                return
            }
            let delay = Self.retryDelays[attempt]
            retries[device.id] = attempt + 1
            Log.debug("\(device.name): this interface does not answer HID++, trying again in \(Int(delay)) s", "devices")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak device] in
                MainActor.assumeIsolated {
                    guard let self, let device, self.isPresent(device), device.state == .notHIDPP else { return }
                    Task { await self.setUp(device) }
                }
            }
            return
        }
        retries[device.id] = nil
        guard isPresent(device) else { return }
        if !devices.contains(where: { $0 === device }) {
            devices.append(device)
            devices.sort { $0.name < $1.name }
        }
        device.onEvent = { [weak self, weak device] event in
            guard let self, let device else { return }
            self.handle(event, from: device)
        }
        Log.info("\(device.name) ready", "devices")
        restoreBacklight(device)
        EventJournal.shared.record(JournalEvent(time: Date(), kind: .connected, device: device.name))
        await apply(to: device)
    }

    // MARK: - Config → devices

    private func applyAll() {
        for device in devices {
            Task { await apply(to: device) }
        }
    }

    private func apply(to device: LogiDevice) async {
        var wanted: [UInt16: Bool] = [:]
        for control in device.divertable {
            let binding = config.binding(control.cid)
            if isLearning {
                wanted[control.cid] = false
            } else if binding.isTakenOver {
                wanted[control.cid] = binding.usesSwipes && control.hasRawXY
            }
        }
        if await !device.divert(wanted) {
            // A write failed (the device was busy reconnecting): try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak device] in
                MainActor.assumeIsolated {
                    guard let self, let device, self.isPresent(device), device.state == .ready else { return }
                    Task { await self.apply(to: device) }
                }
            }
        }

        guard let current = device.smartShift else { return }
        if config.smartShift.threshold == nil {
            // First run: keep what Logi Options+ had set.
            ConfigStore.shared.config.smartShift.threshold = Int(current.threshold)
            Log.info("SmartShift threshold \(current.threshold) taken from the mouse", "devices")
        } else if config.smartShift.enabled, let threshold = config.smartShift.threshold, Int(current.threshold) != threshold {
            await device.writeSmartShift(threshold: threshold)
        }
    }

    // MARK: - Learning a key

    func startLearning() {
        isLearning = true
        learned = nil
        applyAll()
        let work = DispatchWorkItem { [weak self] in self?.stopLearning() }
        learnTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        Log.info("Learning: waiting for a key", "devices")
    }

    func stopLearning() {
        learnTimeout?.cancel()
        guard isLearning else { return }
        isLearning = false
        applyAll()
    }

    // MARK: - Events

    private func handle(_ event: LogiDevice.Event, from device: LogiDevice) {
        switch event {
        case .down(let cid):
            if isLearning {
                learned = (device.name, cid)
                Log.info("Learned: \(device.name) \(String(format: "0x%04X", cid))", "devices")
                stopLearning()
                return
            }
            let binding = config.binding(cid)
            if binding.usesSwipes {
                if let held = gestureControl {
                    Log.warning("Gesture: \(KnownControl.name(cid)) pressed while \(KnownControl.name(held)) still held (release lost?)", "gesture")
                }
                gestureControl = cid
                gesture.threshold = config.swipeThreshold
                gesture.begin()
                gestureTrace = GestureTrace()
                gestureTrace.pointerDown = NSEvent.mouseLocation
                gestureStart = DispatchTime.now().uptimeNanoseconds
            } else {
                ActionRunner.run(binding.click, source: KnownControl.name(cid))
            }
        case .up(let cid):
            guard cid == gestureControl else {
                if config.binding(cid).usesSwipes { Log.warning("Gesture: \(KnownControl.name(cid)) released without a press", "gesture") }
                return
            }
            gestureControl = nil
            gestureTrace.pointerUp = NSEvent.mouseLocation
            let swipe = gestureTrace.decision.map { config.binding(cid).swipe($0.direction).title }
            let wasClick = gesture.end()
            let result = wasClick
                ? "click → \(config.binding(cid).click.title)"
                : "swipe \(gestureTrace.decision?.direction.rawValue ?? "?") → \(swipe ?? "?")"
            let held = gestureMilliseconds()
            if gestureTrace.looksWrong() {
                Log.warning("Gesture looks wrong: " + gestureTrace.summary(held: held, threshold: gesture.threshold, result: result), "gesture")
            } else {
                Log.info("Gesture: " + gestureTrace.summary(held: held, threshold: gesture.threshold, result: result,
                                                            withMoves: Log.verbose), "gesture")
            }
            if wasClick {
                ActionRunner.run(config.binding(cid).click, source: KnownControl.name(cid))
            }
        case .move(let dx, let dy):
            guard let cid = gestureControl else { return }
            gestureTrace.add(ms: gestureMilliseconds(), dx: dx, dy: dy)
            guard let direction = gesture.move(dx: dx, dy: dy) else { return }
            gestureTrace.decision = (gestureTrace.samples.count - 1, direction, gesture.dx, gesture.dy)
            ActionRunner.run(config.binding(cid).swipe(direction), source: "\(KnownControl.name(cid)), \(direction.title.lowercased())")
        }
    }

    private func gestureMilliseconds() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - gestureStart) / 1_000_000)
    }
}
