import Foundation

/// Names of Logitech control IDs (CIDs). The keyboard's come from Logitech's own key map
/// (`depots/*/mx_keys_mini/metadata.json` in Logi Options+: slot `…_c<CID in decimal>` → F-key),
/// the mouse's from the Options+ settings. A code not on that map (0x0117 was Del with the lock icon) is listed
/// apart in the settings until named here; "Определить клавишу" tells which key it is.
enum KnownControl {
    static let middleButton: UInt16 = 0x0052
    static let back: UInt16 = 0x0053
    static let forward: UInt16 = 0x0056
    static let gestureButton: UInt16 = 0x00C3
    static let modeShift: UInt16 = 0x00C4
    static let backlightDown: UInt16 = 0x00E2
    static let backlightUp: UInt16 = 0x00E3
    static let dictation: UInt16 = 0x0103
    static let emoji: UInt16 = 0x0108
    static let screenCapture: UInt16 = 0x010A
    static let micMute: UInt16 = 0x011C

    /// The "virtual gesture button": no physical button, Logi Options+ bookkeeping.
    static let virtualGesture: UInt16 = 0x00D7

    static let names: [UInt16: String] = [
        0x0050: "Левая кнопка",
        0x0051: "Правая кнопка",
        middleButton: "Средняя кнопка (нажатие колеса)",
        back: "Назад",
        forward: "Вперёд",
        gestureButton: "Кнопка под большим пальцем",
        modeShift: "Кнопка под колесом (режим колеса)",
        0x00D1: "F1 (устройство 1)",
        0x00D2: "F2 (устройство 2)",
        0x00D3: "F3 (устройство 3)",
        backlightDown: "F4 (подсветка −)",
        backlightUp: "F5 (подсветка +)",
        dictation: "F6 (диктовка)",
        emoji: "F7 (эмодзи)",
        screenCapture: "F8 (скриншот)",
        micMute: "F9 (микрофон)",
        0x00E5: "F10 (пауза / воспроизведение)",
        0x00E7: "F11 (без звука)",
        0x00E8: "F12 (тише)",
        0x00E9: "Insert (громче)",
        // Not on Logitech's key map; found by pressing it (2026-10-19).
        0x0117: "Del / замок (правый верхний угол)",
    ]

    /// What the button does on its own (MXCtl leaves it alone), for "… — по умолчанию".
    static let defaults: [UInt16: String] = [
        0x0052: "Средняя кнопка",
        back: "Назад",
        forward: "Вперёд",
        gestureButton: "Mission Control",
        modeShift: "Переключить режим колеса",
        backlightDown: "Подсветка −",
        backlightUp: "Подсветка +",
        dictation: "Диктовка",
        emoji: "Эмодзи",
        screenCapture: "Снимок экрана macOS",
        micMute: "Микрофон вкл/выкл",
        0x00E5: "Пауза / воспроизведение",
        0x00E7: "Выключить звук",
        0x00E8: "Тише",
        0x00E9: "Громче",
        0x0117: "Delete",
    ]

    /// Logitech's out-of-the-box action where the key does not do it by itself and MXCtl does it
    /// (as Options+ did): the mic key, and the gesture button's "window navigation". A button set to
    /// this is "by default", not "changed".
    static func factory(_ cid: UInt16) -> ButtonBinding {
        switch cid {
        case micMute:
            return ButtonBinding(click: .system(.micMute))
        case gestureButton:
            return ButtonBinding(click: .system(.missionControl), up: .system(.missionControl), down: .system(.appExpose),
                                 left: .system(.desktopLeft), right: .system(.desktopRight))
        default:
            return ButtonBinding()
        }
    }

    /// "Выключить микрофон — по умолчанию".
    static func defaultTitle(_ cid: UInt16) -> String {
        let factory = factory(cid).click
        let name = factory == .native ? (defaults[cid] ?? "Своё действие устройства") : factory.title
        return "\(name) — по умолчанию"
    }

    /// The user changed it from the default.
    static func isChanged(_ cid: UInt16, _ binding: ButtonBinding) -> Bool { binding != factory(cid) }

    static func name(_ cid: UInt16) -> String {
        names[cid] ?? String(format: "Кнопка 0x%04X", cid)
    }
}
