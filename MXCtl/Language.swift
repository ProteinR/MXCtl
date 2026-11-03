import AppKit
import SwiftUI

/// The interface language: the system's by default (Russian on a Russian Mac, English otherwise),
/// or chosen in Общие. Stored as the app's own `AppleLanguages`, which macOS reads at launch, so a
/// change needs a restart. Strings are written in Russian in the code; `en.lproj` translates them.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en

    var id: String { rawValue }

    private static let key = "AppleLanguages"

    /// Set only in the app's own domain: `UserDefaults.standard` also sees the global list.
    static var chosen: AppLanguage {
        get {
            let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
            let first = (domain?[key] as? [String])?.first
            return first.flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: key)
            }
        }
    }

    /// The language the interface is in now (picked at launch).
    static var running: AppLanguage {
        Bundle.main.preferredLocalizations.first.flatMap(AppLanguage.init(rawValue:)) ?? .en
    }

    /// The language the system choice gives, by the system's preferred languages.
    static var systemLanguage: AppLanguage {
        let available = Bundle.main.localizations.filter { $0 != "Base" }
        let preferred = Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages)
        return preferred.first.flatMap(AppLanguage.init(rawValue:)) ?? .en
    }

    /// Each language in its own name, so it can be found whatever language the interface is in.
    var title: String {
        switch self {
        case .system: return String(localized: "Как в системе (\(Self.systemLanguage.title))")
        case .ru: return "Русский"  // no-l10n
        case .en: return "English"
        }
    }

    private static let reopenSettingsKey = "reopenSettingsAfterRestart"

    /// Starts a new copy once this one has quit, and quits; the new one opens the settings again.
    @MainActor
    static func restart() {
        UserDefaults.standard.set(true, forKey: reopenSettingsKey)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
                             Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            Log.error("Restart failed: \(Log.describe(error))")
            return
        }
        Log.info("Restarting for the language: \(chosen.rawValue)")
        NSApp.terminate(nil)
    }

    /// After `restart()`: the settings window again, on Общие.
    @MainActor
    static func reopenSettingsIfRestarted() {
        guard UserDefaults.standard.bool(forKey: reopenSettingsKey) else { return }
        UserDefaults.standard.removeObject(forKey: reopenSettingsKey)
        SettingsWindow.shared.show(tab: "Общие")  // no-l10n
    }
}

/// Общие → Язык. The choice is saved at once; the button restarts MXCtl to apply it.
struct LanguagePicker: View {
    @State private var chosen = AppLanguage.chosen

    var body: some View {
        Picker("Язык", selection: Binding(get: { chosen }, set: { chosen = $0; AppLanguage.chosen = $0 })) {
            ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
        }
        if (chosen == .system ? AppLanguage.systemLanguage : chosen) != AppLanguage.running {
            HStack {
                Text("Язык сменится после перезапуска.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Перезапустить MXCtl") { AppLanguage.restart() }
            }
        }
    }
}
