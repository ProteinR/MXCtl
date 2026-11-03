import AppKit
import SwiftUI

/// "Сообщить об ошибке": a window with the report as read-only text (a template to fill in, what
/// MXCtl knows about the Mac and the devices, and the end of the log); a click copies all of it, to
/// paste into any mail. Handing the log to the default mail app as an attachment was lost silently
/// when that app was a browser with web mail.
enum BugReport {
    static let address = "contact@memruk.dev"
    static var subject: String { "MXCtl \(AppDelegate.appVersion): ошибка / bug report" }  // no-l10n
    /// Enough of the log to see what happened just before, small enough to paste into a mail.
    private static let logLines = 300

    @MainActor
    static func compose() {
        BugReportWindow.shared.show()
        Log.info("Bug report: window opened")
    }

    /// The template, the facts and the last lines of the log.
    @MainActor
    static func report() -> String {
        text() + "\n" + logTail()
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

        The end of the log (device names, key codes and actions, no typed text):
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
            Text("Нажмите на текст, чтобы скопировать его, и вставьте в письмо на \(BugReport.address). Опишите, что случилось, в начале.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(copied ? Color.green : Color.primary.opacity(0.15)))
            .contentShape(Rectangle())
            .onTapGesture { copy() }
            .help("Нажмите, чтобы скопировать")
            HStack {
                if copied {
                    Label("Скопировано", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Показать лог в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                }
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
