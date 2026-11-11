import AppKit
import Carbon.HIToolbox
import Combine

/// A key combination to send: virtual key code and modifiers (Carbon `kVK_*`, `NSEvent.ModifierFlags`).
struct Keystroke: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt
    /// What the user saw when recording it ("4", "←"), for the label.
    var label: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var title: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (KeyNames.modifierKeys[Int(keyCode)]?.title ?? label)
    }

    /// A modifier key alone (right ⌃): pressed and released as a modifier, held while the button is.
    var modifierKey: KeyNames.ModifierKey? { KeyNames.modifierKeys[Int(keyCode)] }

    static let screenshotArea = Keystroke(keyCode: UInt16(kVK_ANSI_4), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "4")
}

/// macOS functions that have no single key combination of their own.
enum SystemAction: String, Codable, CaseIterable, Identifiable {
    case missionControl, appExpose, showDesktop, desktopLeft, desktopRight, launchpad, micMute, lockScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appExpose: return String(localized: "Окна приложения (App Exposé)")
        case .showDesktop: return String(localized: "Показать рабочий стол")
        case .desktopLeft: return String(localized: "Рабочий стол слева")
        case .desktopRight: return String(localized: "Рабочий стол справа")
        case .launchpad: return String(localized: "Приложения (Launchpad)")
        case .micMute: return String(localized: "Микрофон вкл/выкл")
        case .lockScreen: return String(localized: "Заблокировать экран")
        }
    }
}

/// The media keys macOS knows (`NX_KEYTYPE_*`).
enum MediaAction: Int, Codable, CaseIterable, Identifiable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    case playPause = 16, next = 17, previous = 18
    case keyboardLightUp = 21, keyboardLightDown = 22

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .volumeUp: return String(localized: "Громче")
        case .volumeDown: return String(localized: "Тише")
        case .mute: return String(localized: "Выключить звук")
        case .brightnessUp: return String(localized: "Яркость +")
        case .brightnessDown: return String(localized: "Яркость −")
        case .playPause: return String(localized: "Пауза / воспроизведение")
        case .next: return String(localized: "Следующий трек")
        case .previous: return String(localized: "Предыдущий трек")
        case .keyboardLightUp: return String(localized: "Подсветка клавиатуры +")
        case .keyboardLightDown: return String(localized: "Подсветка клавиатуры −")
        }
    }
}

/// What a key, button or swipe does. `native` leaves the key to the device (MXCtl does not take it
/// over); everything else is done by MXCtl.
enum Action: Codable, Hashable {
    case native
    case nothing
    case keystroke(Keystroke)
    case system(SystemAction)
    case media(MediaAction)
    /// An app (also your own) by its path.
    case openApp(path: String)
    /// Any URL: a site, an app's URL scheme, `shortcuts://run-shortcut?name=…`.
    case openURL(String)
    /// A command for the Shortcuts app.
    case shortcut(name: String)
    /// A shell command (`/bin/zsh -lc`), for automation.
    case shell(String)

    var title: String {
        switch self {
        case .native: return String(localized: "По умолчанию")
        case .nothing: return String(localized: "Ничего")
        case .keystroke(let keystroke): return String(localized: "Нажать \(keystroke.title)")
        case .system(let action): return action.title
        case .media(let action): return action.title
        case .openApp(let path):
            let app = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            return String(localized: "Открыть \(app)")
        case .openURL(let url): return String(localized: "Ссылка \(url)")
        case .shortcut(let name): return String(localized: "Команда «\(name)»")
        case .shell(let command): return "Shell: \(command)"
        }
    }
}

/// What a control does: a press, and for buttons that report mouse movement while held (the
/// gesture button), a swipe in each direction.
struct ButtonBinding: Codable, Hashable {
    var click: Action = .native
    var up: Action = .native
    var down: Action = .native
    var left: Action = .native
    var right: Action = .native

    var usesSwipes: Bool { [up, down, left, right].contains { $0 != .native } }
    var isTakenOver: Bool { click != .native || usesSwipes }

    func swipe(_ direction: SwipeDirection) -> Action {
        switch direction {
        case .up: return up
        case .down: return down
        case .left: return left
        case .right: return right
        }
    }

    init(click: Action = .native, up: Action = .native, down: Action = .native, left: Action = .native, right: Action = .native) {
        self.click = click
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        click = try c.decodeIfPresent(Action.self, forKey: .click) ?? .native
        up = try c.decodeIfPresent(Action.self, forKey: .up) ?? .native
        down = try c.decodeIfPresent(Action.self, forKey: .down) ?? .native
        left = try c.decodeIfPresent(Action.self, forKey: .left) ?? .native
        right = try c.decodeIfPresent(Action.self, forKey: .right) ?? .native
    }
}

/// A key MXCtl catches by its key event (the Mac's own keyboard, or any other keyboard), not over
/// HID++: an ordinary key (virtual key code, also the Apple top-row codes 160/176/177/178) or a
/// media key (`NX_KEYTYPE_*`), with the modifiers held. Fn is ignored: the top row sends F5 with
/// Fn and the dictation code without it.
struct KeyTrigger: Codable, Hashable {
    enum Kind: String, Codable { case key, media }

    var kind: Kind
    var code: Int
    /// `NSEvent.ModifierFlags`: command, shift, option, control only.
    var modifiers: UInt = 0
    /// What the key typed when it was added ("Q"), for keys without a name of their own.
    var label = ""

    /// What two triggers are compared by (the label is only for showing).
    var matchKey: String { "\(kind.rawValue):\(code):\(modifiers)" }

    var title: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (KeyNames.name(kind: kind, code: code) ?? (label.isEmpty ? "#\(code)" : label))
    }
}

/// One taken-over key and what it does now.
struct MacKeyBinding: Codable, Hashable, Identifiable {
    var trigger: KeyTrigger
    var action: Action = .native

    var id: String { trigger.matchKey }
}

/// Names of keys that do not type a character.
enum KeyNames {
    static func name(kind: KeyTrigger.Kind, code: Int) -> String? {
        switch kind {
        case .media:
            if let media = MediaAction(rawValue: code) { return media.title }
            switch code {
            case 19: return String(localized: "Перемотка вперёд")
            case 20: return String(localized: "Перемотка назад")
            case 23: return String(localized: "Подсветка клавиатуры вкл/выкл")
            default: return String(localized: "Медиаклавиша \(code)")
            }
        case .key:
            switch code {
            // The Apple keyboard's top row without Fn.
            case 160: return String(localized: "Mission Control (F3)")
            case 176: return String(localized: "Диктовка (F5, микрофон)")
            case 177: return String(localized: "Spotlight (F4)")
            case 178: return String(localized: "Не беспокоить (F6)")
            case 131: return "Launchpad"
            default: return specialKeys[code]
            }
        }
    }

    /// A modifier key: its flag, the device-dependent bit it sets in `CGEventFlags` while down
    /// (which tells right ⌃ from left; apps such as Genius Typer look at it) and its name.
    struct ModifierKey {
        let flag: CGEventFlags
        let deviceMask: UInt64
        let title: String
    }

    static let modifierKeys: [Int: ModifierKey] = [
        kVK_RightOption: ModifierKey(flag: .maskAlternate, deviceMask: 0x40, title: String(localized: "Правый ⌥")),
        kVK_Option: ModifierKey(flag: .maskAlternate, deviceMask: 0x20, title: String(localized: "Левый ⌥")),
        kVK_RightCommand: ModifierKey(flag: .maskCommand, deviceMask: 0x10, title: String(localized: "Правый ⌘")),
        kVK_Command: ModifierKey(flag: .maskCommand, deviceMask: 0x08, title: String(localized: "Левый ⌘")),
        kVK_RightControl: ModifierKey(flag: .maskControl, deviceMask: 0x2000, title: String(localized: "Правый ⌃")),
        kVK_Control: ModifierKey(flag: .maskControl, deviceMask: 0x01, title: String(localized: "Левый ⌃")),
        kVK_RightShift: ModifierKey(flag: .maskShift, deviceMask: 0x04, title: String(localized: "Правый ⇧")),
        kVK_Shift: ModifierKey(flag: .maskShift, deviceMask: 0x02, title: String(localized: "Левый ⇧")),
    ]

    static let specialKeys: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: String(localized: "Пробел"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "Esc", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
}

enum SwipeDirection: String, CaseIterable {
    case up, down, left, right

    var title: String {
        switch self {
        case .up: return String(localized: "Свайп вверх")
        case .down: return String(localized: "Свайп вниз")
        case .left: return String(localized: "Свайп влево")
        case .right: return String(localized: "Свайп вправо")
        }
    }
}

/// Mouse wheel smoothing and direction, the Mos settings (values are in Mos's units). The defaults
/// are the owner's own tuning (Mos had step 50, speed 1.07).
struct ScrollSettings: Codable, Equatable {
    var smooth = true
    var smoothVertical = true
    var smoothHorizontal = true
    var reverseVertical = true
    var reverseHorizontal = true
    /// Minimal distance of one wheel notch, points.
    var step = 65.0
    /// Multiplier of the distance.
    var speed = 1.8
    /// Animation length, 0…5 (Mos "Продолжительность"); larger is longer.
    var duration = 2.75

    var isActive: Bool { smooth || reverseVertical || reverseHorizontal }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScrollSettings()
        smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth) ?? d.smooth
        smoothVertical = try c.decodeIfPresent(Bool.self, forKey: .smoothVertical) ?? d.smoothVertical
        smoothHorizontal = try c.decodeIfPresent(Bool.self, forKey: .smoothHorizontal) ?? d.smoothHorizontal
        reverseVertical = try c.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? d.reverseVertical
        reverseHorizontal = try c.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? d.reverseHorizontal
        step = try c.decodeIfPresent(Double.self, forKey: .step) ?? d.step
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? d.duration
    }
}

/// SmartShift written to the mouse on every connect. nil threshold: not read from the mouse yet
/// (MXCtl then keeps what the mouse has).
struct SmartShiftSettings: Codable, Equatable {
    var enabled = true
    /// 1…254: how fast the wheel must turn to spin free; 255 = always ratchet.
    var threshold: Int?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        threshold = try c.decodeIfPresent(Int.self, forKey: .threshold)
    }
}

struct Config: Codable, Equatable {
    /// By control ID ("010A"), the same for every device that has it.
    var bindings: [String: ButtonBinding] = Config.defaultBindings
    var scroll = ScrollSettings()
    var smartShift = SmartShiftSettings()
    /// Mouse movement (device units) that counts as a swipe while the gesture button is held.
    /// Real swipes add up to 300–1800; 100 keeps the press jolt (~50) from counting.
    var swipeThreshold = 100
    /// Battery notifications, percent.
    var batteryWarning = 15
    var batteryCritical = 5
    /// Keyboard backlight off while the Mac sleeps (and its screens are off), back on at wake.
    var backlightOffOnSleep = true
    /// Keys of the Mac's own keyboard (and others) taken over by their key events (`KeyRemap`).
    var macKeys: [MacKeyBinding] = []

    static func key(_ cid: UInt16) -> String { String(format: "%04X", cid) }

    /// The owner's Logi Options+ setup (see AGENTS.md). Swipes go like a trackpad: dragging right
    /// pulls the desktop on the left into view.
    static let defaultBindings: [String: ButtonBinding] = [
        key(KnownControl.screenCapture): ButtonBinding(click: .keystroke(.screenshotArea)),
        key(KnownControl.micMute): ButtonBinding(click: .system(.micMute)),
        key(KnownControl.gestureButton): ButtonBinding(click: .system(.missionControl), up: .system(.missionControl),
                                                       down: .system(.appExpose), left: .system(.desktopRight),
                                                       right: .system(.desktopLeft)),
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindings = try c.decodeIfPresent([String: ButtonBinding].self, forKey: .bindings) ?? Config.defaultBindings
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? ScrollSettings()
        smartShift = try c.decodeIfPresent(SmartShiftSettings.self, forKey: .smartShift) ?? SmartShiftSettings()
        swipeThreshold = try c.decodeIfPresent(Int.self, forKey: .swipeThreshold) ?? 100
        batteryWarning = try c.decodeIfPresent(Int.self, forKey: .batteryWarning) ?? 15
        batteryCritical = try c.decodeIfPresent(Int.self, forKey: .batteryCritical) ?? 5
        backlightOffOnSleep = try c.decodeIfPresent(Bool.self, forKey: .backlightOffOnSleep) ?? true
        macKeys = try c.decodeIfPresent([MacKeyBinding].self, forKey: .macKeys) ?? []
    }

    func binding(_ cid: UInt16) -> ButtonBinding { bindings[Config.key(cid)] ?? ButtonBinding() }
}

/// `~/Library/Application Support/MXCtl/config.json`: edited in the settings window, or by hand
/// ("Перечитать" in the panel picks hand edits up).
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
        }
    }

    nonisolated static let fileURL: URL = {
        let dir = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("MXCtlTests", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MXCtl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    private var saveWork: DispatchWorkItem?

    private init() {
        config = Self.load() ?? Config()
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) { save() }
    }

    func binding(_ cid: UInt16) -> ButtonBinding { config.binding(cid) }

    func setBinding(_ binding: ButtonBinding, for cid: UInt16) {
        config.bindings[Config.key(cid)] = binding
    }

    func reload() {
        if let loaded = Self.load() {
            config = loaded
            Log.info("Config reloaded", "config")
        }
    }

    private static func load() -> Config? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.error("Config file unreadable, keeping the current settings: \(error)", "config")
            return nil
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(config).write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.error("Cannot save config: \(Log.describe(error))", "config")
        }
    }
}
