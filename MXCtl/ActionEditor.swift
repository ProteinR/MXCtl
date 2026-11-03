import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Picks an action: a menu of kinds, then what the kind needs (a key combination, an app, a URL…).
struct ActionEditor: View {
    @Binding var action: Action
    /// What "по умолчанию" means for this button: the device's own (`.native`) or Logitech's
    /// default that MXCtl performs (the mic key). Not listed twice.
    var defaultAction: Action = .native
    var defaultTitle = "По умолчанию"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A Menu, not a Picker: its ~25 items are made only when it opens. Pickers made them
            // for every row at once and the settings list scrolled jerkily.
            Menu {
                item(defaultTitle, defaultAction)
                if defaultAction != .nothing { item("Ничего не делать", .nothing) }
                Divider()
                Button("Сочетание клавиш…") { select("keystroke") }
                Divider()
                ForEach(SystemAction.allCases.filter { .system($0) != defaultAction }) { item($0.title, .system($0)) }
                Divider()
                ForEach(MediaAction.allCases) { item($0.title, .media($0)) }
                Divider()
                Button("Открыть приложение…") { select("openApp") }
                Button("Открыть ссылку / URL-схему…") { select("openURL") }
                Button("Запустить команду Shortcuts…") { select("shortcut") }
                Button("Выполнить shell-команду…") { select("shell") }
            } label: {
                Text(menuTitle)
            }
            .fixedSize()

            details
        }
    }

    private func item(_ title: String, _ value: Action) -> some View {
        Button(title) { action = value }
    }

    private func select(_ kind: String) {
        action = Self.action(for: kind, current: action)
    }

    /// The kind, short; the details below show the rest.
    private var menuTitle: String {
        if action == defaultAction { return defaultTitle }
        switch action {
        case .native: return "Своё действие устройства"
        case .nothing: return "Ничего не делать"
        case .keystroke: return "Сочетание клавиш"
        case .system(let system): return system.title
        case .media(let media): return media.title
        case .openApp: return "Открыть приложение"
        case .openURL: return "Открыть ссылку"
        case .shortcut: return "Команда Shortcuts"
        case .shell: return "Shell-команда"
        }
    }

    @ViewBuilder
    private var details: some View {
        switch action {
        case .keystroke(let keystroke):
            HStack {
                ShortcutRecorder(keystroke: Binding(get: { keystroke }, set: { action = .keystroke($0) }))
                Button("⌘⇧4 (скриншот)") { action = .keystroke(.screenshotArea) }
                    .buttonStyle(.link).font(.caption)
            }
        case .openApp(let path):
            HStack {
                Text(path.isEmpty ? "Приложение не выбрано" : FileManager.default.displayName(atPath: path))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                Button("Выбрать…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url { action = .openApp(path: url.path) }
                }
            }
        case .openURL(let url):
            field("https://… или myapp://…", url) { action = .openURL($0) }
        case .shortcut(let name):
            field("Название команды", name) { action = .shortcut(name: $0) }
        case .shell(let command):
            field("Команда, например open -a Terminal", command) { action = .shell($0) }
        default:
            EmptyView()
        }
    }

    private func field(_ prompt: String, _ value: String, set: @escaping (String) -> Void) -> some View {
        TextField(prompt, text: Binding(get: { value }, set: set))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
    }

    static func kind(of action: Action) -> String {
        switch action {
        case .native: return "native"
        case .nothing: return "nothing"
        case .keystroke: return "keystroke"
        case .system(let system): return "system.\(system.rawValue)"
        case .media(let media): return "media.\(media.rawValue)"
        case .openApp: return "openApp"
        case .openURL: return "openURL"
        case .shortcut: return "shortcut"
        case .shell: return "shell"
        }
    }

    static func action(for kind: String, current: Action) -> Action {
        if kind == Self.kind(of: current) { return current }
        switch kind {
        case "native": return .native
        case "nothing": return .nothing
        case "keystroke": return .keystroke(.screenshotArea)
        case "openApp": return .openApp(path: "")
        case "openURL": return .openURL("")
        case "shortcut": return .shortcut(name: "")
        case "shell": return .shell("")
        default:
            if kind.hasPrefix("system."), let system = SystemAction(rawValue: String(kind.dropFirst(7))) { return .system(system) }
            if kind.hasPrefix("media."), let raw = Int(kind.dropFirst(6)), let media = MediaAction(rawValue: raw) { return .media(media) }
            return .native
        }
    }
}

/// "Записать": the next key combination typed becomes the keystroke; Esc cancels.
struct ShortcutRecorder: View {
    @Binding var keystroke: Keystroke
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Нажмите сочетание…" : keystroke.title) {
            recording ? stop() : start()
        }
        .frame(minWidth: 120)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            keystroke = Keystroke(keyCode: event.keyCode, modifiers: modifiers.rawValue, label: Self.label(for: event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static let specialKeys: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "Пробел", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    private static func label(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
