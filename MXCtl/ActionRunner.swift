import AppKit
import Carbon.HIToolbox

/// Does an `Action`: posts key combinations and media keys, opens apps and URLs, runs commands.
/// Posting events needs the Accessibility permission.
@MainActor
enum ActionRunner {
    /// Events MXCtl posts carry this, so its own scroll tap lets them through.
    nonisolated static let eventMarker: Int64 = 0x4D58_4354 // "MXCT"

    static func run(_ action: Action, source: String) {
        Log.info("\(source) → \(action.title)", "action")
        switch action {
        case .native, .nothing:
            break
        case .keystroke(let keystroke):
            post(keystroke)
        case .system(let system):
            run(system)
        case .media(let media):
            postMedia(media)
        case .openApp(let path):
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, error in
                if let error { Log.error("Open \(path): \(Log.describe(error))", "action") }
            }
        case .openURL(let string):
            guard let url = URL(string: string) else {
                Log.error("Not a URL: \(string)", "action")
                return
            }
            NSWorkspace.shared.open(url)
        case .shortcut(let name):
            launch("/usr/bin/shortcuts", ["run", name])
        case .shell(let command):
            launch("/bin/zsh", ["-lc", command])
        }
    }

    private static func run(_ action: SystemAction) {
        switch action {
        // The Dock does these; another process may not start the Mission Control app itself
        // (macOS kills it with exit 9).
        case .missionControl: Dock.send("com.apple.expose.awake")
        case .appExpose: Dock.send("com.apple.expose.front.awake")
        case .showDesktop: Dock.send("com.apple.showdesktop.awake")
        // macOS shortcuts ⌃← / ⌃→ (System Settings → Keyboard → Shortcuts → Mission Control).
        case .desktopLeft: post(Keystroke(keyCode: UInt16(kVK_LeftArrow), modifiers: NSEvent.ModifierFlags.control.rawValue, label: "←"))
        case .desktopRight: post(Keystroke(keyCode: UInt16(kVK_RightArrow), modifiers: NSEvent.ModifierFlags.control.rawValue, label: "→"))
        case .launchpad:
            NSWorkspace.shared.open(appsURL())
        case .micMute:
            // The red indicator follows the mic itself (MicIndicator).
            _ = Microphone.toggle()
            MicIndicator.shared.refresh()
        case .lockScreen:
            post(Keystroke(keyCode: UInt16(kVK_ANSI_Q), modifiers: NSEvent.ModifierFlags([.control, .command]).rawValue, label: "Q"))
        }
    }

    private static func appsURL() -> URL {
        // macOS 26 replaced Launchpad with Apps.
        for path in ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
        where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/System/Applications/Launchpad.app")
    }

    /// Arrow and function keys carry the Fn and keypad flags when typed; macOS matches its own
    /// shortcuts (⌃← for desktops) only with them.
    private static let fnKeys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                           kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
                                           kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                           kVK_F9, kVK_F10, kVK_F11, kVK_F12]
    private static let arrowKeys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]

    static func post(_ keystroke: Keystroke) {
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = CGEventFlags()
        let modifiers = keystroke.flags
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if fnKeys.contains(Int(keystroke.keyCode)) { flags.insert(.maskSecondaryFn) }
        if arrowKeys.contains(Int(keystroke.keyCode)) { flags.insert(.maskNumericPad) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keystroke.keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    static func postMedia(_ key: MediaAction) {
        for down in [true, false] {
            let data1 = (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func launch(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                Log.warning("\(path) \(arguments) exited with \(process.terminationStatus)", "action")
            }
        }
        do {
            try process.run()
        } catch {
            Log.error("Cannot run \(path): \(Log.describe(error))", "action")
        }
    }
}

/// `CoreDockSendNotification` (private, in HIServices): asks the Dock for Mission Control,
/// App Exposé or the desktop, as the trackpad gestures do.
private enum Dock {
    private typealias SendNotification = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void

    private static let function: SendNotification? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDockSendNotification") else {
            Log.error("CoreDockSendNotification not found", "action")
            return nil
        }
        return unsafeBitCast(symbol, to: SendNotification.self)
    }()

    static func send(_ name: String) {
        function?(name as CFString, nil)
    }
}
