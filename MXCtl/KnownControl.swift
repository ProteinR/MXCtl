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
        0x0050: String(localized: "Левая кнопка"),
        0x0051: String(localized: "Правая кнопка"),
        middleButton: String(localized: "Средняя кнопка (нажатие колеса)"),
        back: String(localized: "Назад"),
        forward: String(localized: "Вперёд"),
        gestureButton: String(localized: "Кнопка под большим пальцем"),
        modeShift: String(localized: "Кнопка под колесом (режим колеса)"),
        0x00D1: String(localized: "F1 (устройство 1)"),
        0x00D2: String(localized: "F2 (устройство 2)"),
        0x00D3: String(localized: "F3 (устройство 3)"),
        backlightDown: String(localized: "F4 (подсветка −)"),
        backlightUp: String(localized: "F5 (подсветка +)"),
        dictation: String(localized: "F6 (диктовка)"),
        emoji: String(localized: "F7 (эмодзи)"),
        screenCapture: String(localized: "F8 (скриншот)"),
        micMute: String(localized: "F9 (микрофон)"),
        0x00E5: String(localized: "F10 (пауза / воспроизведение)"),
        0x00E7: String(localized: "F11 (без звука)"),
        0x00E8: String(localized: "F12 (тише)"),
        0x00E9: String(localized: "Insert (громче)"),
        // Not on Logitech's key map; found by pressing it (2026-10-19).
        0x0117: String(localized: "Del / замок (правый верхний угол)"),
    ]

    /// What the button does on its own (MXCtl leaves it alone), for "… — по умолчанию".
    static let defaults: [UInt16: String] = [
        0x0052: String(localized: "Средняя кнопка"),
        back: String(localized: "Назад"),
        forward: String(localized: "Вперёд"),
        gestureButton: "Mission Control",
        modeShift: String(localized: "Переключить режим колеса"),
        backlightDown: String(localized: "Подсветка −"),
        backlightUp: String(localized: "Подсветка +"),
        dictation: String(localized: "Диктовка"),
        emoji: String(localized: "Эмодзи"),
        screenCapture: String(localized: "Снимок экрана macOS"),
        micMute: String(localized: "Микрофон вкл/выкл"),
        0x00E5: String(localized: "Пауза / воспроизведение"),
        0x00E7: String(localized: "Выключить звук"),
        0x00E8: String(localized: "Тише"),
        0x00E9: String(localized: "Громче"),
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
        let name = factory == .native ? (defaults[cid] ?? String(localized: "Своё действие устройства")) : factory.title
        return String(localized: "\(name) — по умолчанию")
    }

    /// The user changed it from the default.
    static func isChanged(_ cid: UInt16, _ binding: ButtonBinding) -> Bool { binding != factory(cid) }

    static func name(_ cid: UInt16) -> String {
        names[cid] ?? String(format: String(localized: "Кнопка 0x%04X"), cid)
    }
}
