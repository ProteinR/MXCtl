import AppKit
import SwiftUI

/// "Сообщить об ошибке": a template to fill in and what MXCtl knows about the Mac and the devices.
/// With Mail as the default mail app: a new e-mail with the logs attached, in one click. With any
/// other (a browser with web mail lost the attachments silently): a window with the report and the
/// end of the log as text to copy and paste into any mail.
enum BugReport {
    static let address = "contact@memruk.dev"
    static var subject: String { "MXCtl \(AppDelegate.appVersion): ошибка / bug report" }  // no-l10n
    /// Enough of the log to see what happened just before, small enough to paste into a mail.
    private static let logLines = 300

    @MainActor
    static func compose() {
        if CommandLine.arguments.contains("--bug-report") || !composeInMail() {
            BugReportWindow.shared.show()
            Log.info("Bug report: window opened")
        }
    }

    /// A new e-mail in Mail with the logs attached; false when Mail is not the default mail app.
    @MainActor
    private static func composeInMail() -> Bool {
        guard let mailto = URL(string: "mailto:"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: mailto),
              Bundle(url: app)?.bundleIdentifier == "com.apple.mail",
              let service = NSSharingService(named: .composeEmail) else { return false }
        let body = text() + "\n\nThe log (mxctl.log) is attached: device names, key codes and actions, no typed text.\n"
        let logs = [Log.fileURL, Log.fileURL.deletingLastPathComponent().appendingPathComponent("mxctl.1.log")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard service.canPerform(withItems: [body]) else { return false }
        service.recipients = [address]
        service.subject = subject
        service.perform(withItems: [body as NSString] + logs.map { $0 as NSURL })
        Log.info("Bug report: e-mail composed in Mail with \(logs.count) log file(s)")
        return true
    }

    /// The template, the facts and the last lines of the log.
    @MainActor
    static func report() -> String {
        text() + "\n\nThe end of the log (device names, key codes and actions, no typed text):\n" + logTail()
    }

    private static func logTail() -> String {
        let urls = [Log.fileURL.deletingLastPathComponent().appendingPathComponent("mxctl.1.log"), Log.fileURL]
        let lines = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(logLines)
        return lines.isEmpty ? "(log is empty)" : lines.joined(separator: "\n")
    }

    /// Opens a new mail to the author with the subject; the report is pasted into it.
    static func openMail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

/// The report window. Made on open and dropped on close, like the settings window.
@MainActor
final class BugReportWindow: NSObject, NSWindowDelegate {
    static let shared = BugReportWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: BugReportView(report: BugReport.report()))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "Сообщить об ошибке")
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 640, height: 560))
            window.center()
            self.window = window
        }
        // Forced to the front, as the settings window (a menu bar app may be refused activation).
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        Memory.giveBackSoon()
    }
}

private struct BugReportView: View {
    let report: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Скопируйте отчёт и вставьте его в письмо на \(BugReport.address). Опишите, что случилось, в начале.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(copied ? Color.green : Color.primary.opacity(0.15)))
            HStack {
                if copied {
                    Label("Скопировано", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Показать лог в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                }
                Button("Скопировать") { copy() }
                Button("Скопировать и открыть письмо") {
                    copy()
                    BugReport.openMail()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 360)
    }

    private func copy() {
        BugReport.copy(report)
        copied = true
        Log.info("Bug report: copied (\(report.count) characters)")
    }
}
