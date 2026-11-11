import AppKit
import Carbon.HIToolbox

/// Keys of the Mac's own keyboard (and any other keyboard) taken over by their key events, for
/// keys MXCtl cannot reach over HID++: e.g. the MacBook's F5 (dictation) → mic mute. A session
/// event tap (Accessibility) sees key presses and media keys (`NX_SYSDEFINED`); a press of a
/// taken-over key runs its action, and the press, its repeats and its release are swallowed so the
/// key's own function (dictation, Spotlight, volume…) does not happen.
///
/// The tap runs on its own thread (a busy main thread must not delay typing) and only while some
/// key is taken over or a key is being recorded ("Добавить клавишу"). It looks at every key press
/// but keeps and logs nothing except the matched keys.
final class KeyRemap: @unchecked Sendable {
    static let shared = KeyRemap()

    /// `NX_SYSDEFINED`: media keys come as this type with subtype 8.
    static let systemDefined = CGEventType(rawValue: 14)!

    private let lock = NSLock()
    // Under `lock`:
    private var actions: [String: Action] = [:]
    /// Pressed keys whose press was swallowed: their repeats and release are swallowed too.
    private var held: Set<String> = []
    private var recorder: (@MainActor (KeyTrigger?) -> Void)?
    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?

    // Main thread only:
    private var thread: Thread?

    /// Follows the config: the keys with an action of their own (`native` leaves a key alone).
    @MainActor
    func apply(_ keys: [MacKeyBinding]) {
        let map = Dictionary(keys.filter { $0.action != .native }.map { ($0.trigger.matchKey, $0.action) },
                             uniquingKeysWith: { first, _ in first })
        lock.withLock { actions = map }
        updateTap()
    }

    /// The next key pressed anywhere becomes a trigger (swallowed); Esc alone cancels (nil).
    @MainActor
    func record(_ done: @escaping @MainActor (KeyTrigger?) -> Void) {
        lock.withLock { recorder = done }
        updateTap()
    }

    @MainActor
    func cancelRecording() {
        let had = lock.withLock { () -> Bool in defer { recorder = nil }; return recorder != nil }
        if had { updateTap() }
    }

    @MainActor
    private func updateTap() {
        let needed = lock.withLock { !actions.isEmpty || recorder != nil }
        if needed { start() } else { stop() }
    }

    @MainActor
    private func start() {
        guard thread == nil else { return }
        let thread = Thread { [self] in runTap() }
        thread.name = "MXCtl key tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    @MainActor
    private func stop() {
        guard thread != nil else { return }
        let (tap, runLoop) = lock.withLock { (self.tap, self.tapRunLoop) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        thread = nil
        lock.withLock {
            self.tap = nil
            tapRunLoop = nil
            held = []
        }
        Log.info("Key tap removed", "keys")
    }

    // MARK: - Tap thread

    private func runTap() {
        let mask = (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))
            | (CGEventMask(1) << CGEventMask(Self.systemDefined.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<KeyRemap>.fromOpaque(refcon!).takeUnretainedValue().handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.error("Cannot create the key tap (Accessibility permission missing?)", "keys")
            return
        }
        let runLoop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let count = lock.withLock {
            self.tap = tap
            tapRunLoop = runLoop
            return actions.count
        }
        Log.info("Key tap installed (\(count) keys taken over)", "keys")
        CFRunLoopRun()
    }

    /// A key event read from the tap: which key, pressed or released, a repeat or not.
    struct Press: Equatable {
        var trigger: KeyTrigger
        var down: Bool
        var isRepeat: Bool
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.warning("Key tap was disabled (\(type.rawValue)), re-enabled", "keys")
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != ActionRunner.eventMarker,
              let press = Self.press(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }
        let key = press.trigger.matchKey

        enum Outcome { case pass, swallow, run(Action), recorded(@MainActor (KeyTrigger?) -> Void, KeyTrigger?) }
        let outcome: Outcome = lock.withLock {
            if !press.down {
                return held.remove(key) != nil ? .swallow : .pass
            }
            if let recorder, !press.isRepeat {
                self.recorder = nil
                let cancel = press.trigger.kind == .key && press.trigger.code == kVK_Escape && press.trigger.modifiers == 0
                held.insert(key)
                return .recorded(recorder, cancel ? nil : press.trigger)
            }
            guard let action = actions[key] else { return held.contains(key) ? .swallow : .pass }
            held.insert(key)
            return press.isRepeat ? .swallow : .run(action)
        }
        switch outcome {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .run(let action):
            let title = press.trigger.title
            Task { @MainActor in ActionRunner.run(action, source: title) }
            return nil
        case .recorded(let done, let trigger):
            Task { @MainActor in
                done(trigger)
                self.updateTap()
            }
            return nil
        }
    }

    /// Modifier keys (and Caps Lock, power) are never triggers.
    private static let ignoredMedia: Set<Int> = [4, 5, 6, 10]

    static func press(type: CGEventType, event: CGEvent) -> Press? {
        let modifiers = modifiers(event.flags)
        switch type {
        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            var label = ""
            if type == .keyDown, KeyNames.name(kind: .key, code: code) == nil {
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
                label = String(utf16CodeUnits: chars, count: length).uppercased()
            }
            return Press(trigger: KeyTrigger(kind: .key, code: code, modifiers: modifiers, label: label),
                         down: type == .keyDown,
                         isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case Self.systemDefined:
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8,
                  let media = media(data1: ns.data1), !ignoredMedia.contains(media.code) else { return nil }
            return Press(trigger: KeyTrigger(kind: .media, code: media.code, modifiers: modifiers),
                         down: media.down, isRepeat: media.isRepeat)
        default:
            return nil
        }
    }

    /// A media key event's `data1`: the key type in the high 16 bits, then the state (0xA down,
    /// 0xB up) and the repeat bit.
    static func media(data1: Int) -> (code: Int, down: Bool, isRepeat: Bool)? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        return (code, state == 0xA, data1 & 0x1 != 0)
    }

    static func modifiers(_ flags: CGEventFlags) -> UInt {
        var result = NSEvent.ModifierFlags()
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        return result.rawValue
    }
}
