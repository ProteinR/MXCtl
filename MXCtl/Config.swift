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
        return text + label
    }

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
