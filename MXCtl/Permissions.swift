import AppKit
import ApplicationServices
import IOKit.hid

/// The two permissions MXCtl needs:
/// - Input Monitoring: to talk to the keyboard and mouse over HID++;
/// - Accessibility: to change wheel events and post key combinations.
/// Polled until both are there (macOS does not notify), then `onChange` runs.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    @Published private(set) var accessibility = AXIsProcessTrusted()

    var onChange: (() -> Void)?
    private var timer: Timer?

    var allGranted: Bool { inputMonitoring && accessibility }

    func start() {
        Log.info("Permissions: Input Monitoring \(inputMonitoring ? "yes" : "no"), Accessibility \(accessibility ? "yes" : "no")")
        guard !allGranted else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { self.poll() }
        }
    }

    private func poll() {
        let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let ax = AXIsProcessTrusted()
        guard input != inputMonitoring || ax != accessibility else { return }
        inputMonitoring = input
        accessibility = ax
        Log.info("Permissions changed: Input Monitoring \(input ? "yes" : "no"), Accessibility \(ax ? "yes" : "no")")
        onChange?()
        if allGranted {
            timer?.invalidate()
            timer = nil
        }
    }

    func requestInputMonitoring() {
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

/// Other apps that would grab the same keys and wheel: Logi Options+ and Mos.
enum Competitors {
    static func running() -> [String] {
        var names: [String] = []
        let apps = NSWorkspace.shared.runningApplications
        if apps.contains(where: { ($0.bundleIdentifier ?? "").hasPrefix("com.logi.") || ($0.executableURL?.lastPathComponent ?? "").hasPrefix("logioptionsplus") }) {
            names.append("Logi Options+")
        }
        if apps.contains(where: { $0.bundleIdentifier == "com.caldis.Mos" }) {
            names.append("Mos")
        }
        return names
    }
}
