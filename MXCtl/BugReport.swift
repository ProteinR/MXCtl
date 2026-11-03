import AppKit

/// "Сообщить об ошибке": a new e-mail to the author with a template to fill in, what MXCtl knows
/// about the Mac and the devices, and the log attached. Mail.app (or any mail app that offers the
/// system "compose e-mail" share) gets the log as an attachment; otherwise a mailto: link opens the
/// default mail app and Finder shows the log to attach by hand.
enum BugReport {
    static let address = "contact@memruk.dev"

    @MainActor
    static func compose() {
        let subject = "MXCtl \(AppDelegate.appVersion): ошибка / bug report"
        let body = text()
        let logs = [Log.fileURL, Log.fileURL.deletingLastPathComponent().appendingPathComponent("mxctl.1.log")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) {
            service.recipients = [address]
            service.subject = subject
            service.perform(withItems: [body as NSString] + logs.map { $0 as NSURL })
            Log.info("Bug report: e-mail composed with \(logs.count) log file(s)")
            return
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [URLQueryItem(name: "subject", value: subject),
                                 URLQueryItem(name: "body", value: body + "\n(Приложите, пожалуйста, лог: он открыт в Finder.)")]
        if let url = components.url { NSWorkspace.shared.open(url) }
        if !logs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(logs) }
        Log.info("Bug report: mailto link opened, log shown in Finder")
    }

    /// The template and the facts, in Russian and English (the app is used by both).
    @MainActor
    static func text() -> String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let permissions = Permissions.shared
        let devices = DeviceManager.shared.devices.map { device in
            var parts = [String(format: "0x%04X", device.productID), "\(device.state)", "\(device.controls.count) controls"]
            if let battery = device.battery { parts.append("battery \(battery) %\(device.charging ? " charging" : "")") }
            if device.smartShift != nil { parts.append("SmartShift") }
            if device.backlight != nil { parts.append("backlight") }
            return "- \(device.name): " + parts.joined(separator: ", ")
        }
        let competitors = Competitors.running()
        return """
        Что случилось / What happened:


        Как повторить / Steps to reproduce:
        1.
        2.

        Что ожидали / What you expected:


        ---
        MXCtl \(AppDelegate.appVersion) (\(build))
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(hardwareModel())
        Input Monitoring: \(permissions.inputMonitoring ? "yes" : "no"), Accessibility: \(permissions.accessibility ? "yes" : "no")
        Also running: \(competitors.isEmpty ? "—" : competitors.joined(separator: ", "))
        Devices:
        \(devices.isEmpty ? "- none found" : devices.joined(separator: "\n"))

        The log (mxctl.log) is attached: device names, key codes and actions, no typed text.
        """
    }

    /// "Mac15,7": the Mac model, as in System Information.
    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
