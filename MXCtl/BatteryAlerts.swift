import Foundation
import UserNotifications

/// When to warn about a low battery: once at `warning` (15 %), once more at `critical` (5 %). Each
/// warning comes once per discharge; charging above `warning` starts over. While charging, nothing.
struct BatteryAlertRule {
    enum Level: Int, Codable {
        case none = 0, warning = 1, critical = 2
    }

    var warning: Int
    var critical: Int

    /// The warning to show now (nil = none) and the level to remember.
    func check(percent: Int, charging: Bool, alreadyShown: Level) -> (show: Level?, remember: Level) {
        if charging || percent > warning { return (nil, .none) }
        let level: Level = percent <= critical ? .critical : .warning
        return level.rawValue > alreadyShown.rawValue ? (level, level) : (nil, alreadyShown)
    }
}

/// Shows the warnings as macOS notifications (visible with the menu bar icon hidden too) and
/// remembers per device which one was shown.
@MainActor
enum BatteryAlerts {
    private static let defaultsKey = "batteryAlertShown"

    static func check(device: String, identity: String, percent: Int, charging: Bool) {
        let config = ConfigStore.shared.config
        let rule = BatteryAlertRule(warning: config.batteryWarning, critical: config.batteryCritical)
        var shown = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        let before = BatteryAlertRule.Level(rawValue: shown[identity] ?? 0) ?? .none
        let result = rule.check(percent: percent, charging: charging, alreadyShown: before)
        if result.remember != before {
            shown[identity] = result.remember.rawValue
            UserDefaults.standard.set(shown, forKey: defaultsKey)
        }
        guard let level = result.show else { return }
        Log.info("\(device): battery \(percent)% → \(level == .critical ? "critical" : "low") warning", "battery")
        notify(title: "\(device): осталось \(percent)%",
               body: level == .critical ? "Скоро выключится — поставьте на зарядку." : "Пора зарядить.",
               level: level)
    }

    /// `level` picks the battery picture (scripts/make-battery.swift).
    static func notify(title: String, body: String, level: BatteryAlertRule.Level = .warning) {
        let center = UNUserNotificationCenter.current()
        center.delegate = ForegroundPresenter.shared
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                Log.warning("Notifications not allowed\(error.map { ": \(Log.describe($0))" } ?? "")", "battery")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let attachment = picture(level) { content.attachments = [attachment] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error {
                    Log.error("Notification failed: \(Log.describe(error))", "battery")
                } else {
                    Log.info("Notification posted: \(title)", "battery")
                }
            }
        }
    }
}

/// The battery picture as an attachment. The system moves the file it is given, so a copy goes.
private func picture(_ level: BatteryAlertRule.Level) -> UNNotificationAttachment? {
    let name = level == .critical ? "battery-critical" : "battery-warning"
    guard let source = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).png")
    do {
        try FileManager.default.copyItem(at: source, to: copy)
        return try UNNotificationAttachment(identifier: name, url: copy)
    } catch {
        Log.warning("Battery picture not attached: \(Log.describe(error))", "battery")
        return nil
    }
}

/// macOS hides an app's notifications while that app is in front (the settings window open, the
/// "Показать пример" button just clicked) unless the app asks to show them anyway.
final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
