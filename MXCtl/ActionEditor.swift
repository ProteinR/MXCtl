import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Picks an action: a menu of kinds, then what the kind needs (a key combination, an app, a URL…).
struct ActionEditor: View {
    @Binding var action: Action
    /// What "по умолчанию" means for this button: the device's own (`.native`) or Logitech's
    /// default that MXCtl performs (the mic key). Not listed twice.
    var defaultAction: Action = .native
    var defaultTitle = String(localized: "По умолчанию")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A Menu, not a Picker: its ~25 items are made only when it opens. Pickers made them
            // for every row at once and the settings list scrolled jerkily.
            Menu {
                item(defaultTitle, defaultAction)
                if defaultAction != .nothing { item(String(localized: "Ничего не делать"), .nothing) }
                Divider()
                Button("Клавиша или сочетание…") { select("keystroke") }
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
        case .native: return String(localized: "Своё действие устройства")
        case .nothing: return String(localized: "Ничего не делать")
        case .keystroke: return String(localized: "Клавиша или сочетание")
        case .system(let system): return system.title
        case .media(let media): return media.title
        case .openApp: return String(localized: "Открыть приложение")
        case .openURL: return String(localized: "Открыть ссылку")
        case .shortcut: return String(localized: "Команда Shortcuts")
        case .shell: return String(localized: "Shell-команда")
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
                Text(path.isEmpty ? String(localized: "Приложение не выбрано") : FileManager.default.displayName(atPath: path))
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

    private func field(_ prompt: LocalizedStringKey, _ value: String, set: @escaping (String) -> Void) -> some View {
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
    /// A modifier key pressed alone so far: released without another key, it is the keystroke.
    @State private var pendingModifier: UInt16?

    var body: some View {
        Button(recording ? String(localized: "Нажмите клавишу или сочетание…") : keystroke.title) {
            recording ? stop() : start()
        }
        .frame(minWidth: 120)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        pendingModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                // Right ⌃ alone (a dictation key, say): down, then up with nothing between.
                guard let modifier = KeyNames.modifierKeys[Int(event.keyCode)] else { return nil }
                let isDown = UInt64(event.modifierFlags.rawValue) & modifier.deviceMask != 0
                if isDown {
                    pendingModifier = event.keyCode
                } else if pendingModifier == event.keyCode {
                    keystroke = Keystroke(keyCode: event.keyCode, modifiers: 0, label: modifier.title)
                    stop()
                }
                return nil
            }
            pendingModifier = nil
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

    private static func label(for event: NSEvent) -> String {
        if let special = KeyNames.specialKeys[Int(event.keyCode)] { return special }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
