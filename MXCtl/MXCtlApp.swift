import AppKit
import Combine
import SwiftUI

@main
struct MXCtlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon is made by AppDelegate (see StatusItemController); SwiftUI needs at
        // least one scene.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// "0.1.0", shown next to the title in the panel.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var statusItem: StatusItemController?
    private var cancellables: Set<AnyCancellable> = []

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.info("MXCtl \(Self.appVersion) (\(build)) started; also running: \(Competitors.running())")
        statusItem = StatusItemController(symbol: "computermouse", title: "MXCtl") {
            AnyView(PanelView()
                .environmentObject(DeviceManager.shared)
                .environmentObject(ConfigStore.shared)
                .environmentObject(Permissions.shared))
        } menuItems: {
            let settings = NSMenuItem(title: String(localized: "Настройки…"), action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
            settings.target = self
            let report = NSMenuItem(title: String(localized: "Сообщить об ошибке…"), action: #selector(AppDelegate.reportBug), keyEquivalent: "")
            report.target = self
            return [settings, report]
        }

        let permissions = Permissions.shared
        permissions.onChange = {
            if permissions.inputMonitoring { DeviceManager.shared.restart() }
            if permissions.accessibility { SmoothScroll.shared.apply(ConfigStore.shared.config.scroll) }
        }
        permissions.start()
        EventJournal.shared.start()
        DeviceManager.shared.start()
        MicIndicator.shared.start()
        ConfigStore.shared.$config
            .map(\.scroll)
            .removeDuplicates()
            .sink { SmoothScroll.shared.apply($0) }
            .store(in: &cancellables)

        if CommandLine.arguments.contains("--settings-scroll-test") { SettingsWindow.shared.runScrollTest() }
        if CommandLine.arguments.contains("--stress-test") { runStressTest() }
        // `--backlight-test`: keyboard backlight off for 4 s and back, to check writing it.
        if CommandLine.arguments.contains("--backlight-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                for device in DeviceManager.shared.devices where device.hasBacklight {
                    Task {
                        _ = await device.setBacklight(enabled: false, reason: String(localized: "тест"))
                        try? await Task.sleep(for: .seconds(4))
                        _ = await device.setBacklight(enabled: true, reason: String(localized: "тест"))
                    }
                }
            }
        }
        // `--open-settings [mouse]`: for screenshots of the settings window.
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { SettingsWindow.shared.show() }
        }
        AppLanguage.reopenSettingsIfRestarted()
        if CommandLine.arguments.contains("--panel-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.statusItem?.runPanelTest() }
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // Keys go back to what the device does on its own.
        DeviceManager.shared.releaseAll()
        Log.info("MXCtl quit")
    }

    /// Opened again from Spotlight or Finder: show the panel (the icon may be hidden).
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showPanel()
        return false
    }

    /// `--stress-test`: three rounds of opening and closing the settings window on every page
    /// (keyboard and mouse pictures, battery charts, scroll, mouse, general) and the panel 10
    /// times, logging how long each page took to open and the memory footprint after each round.
    /// Growing every round = a leak;
    /// growing once and then flat = caches. `leaks <pid>` afterwards lists unreachable memory.
    @MainActor
    private func runStressTest() {
        var cycle = 0
        @MainActor func round() {
            guard cycle < 3 else { return }
            cycle += 1
            var opened = 0
            @MainActor func settings() {
                guard opened < Self.stressPages.count else {
                    self.statusItem?.runPanelTest(rounds: 10)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                        MainActor.assumeIsolated {
                            Log.info("Stress round \(cycle): footprint \(Self.footprintMB()) MB", "stress")
                            round()
                        }
                    }
                    return
                }
                let (tab, mouse) = Self.stressPages[opened]
                opened += 1
                let start = CACurrentMediaTime()
                SettingsWindow.shared.show(tab: tab, mouse: mouse)
                SettingsWindow.shared.layoutNow()
                let took = (CACurrentMediaTime() - start) * 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    Log.info(String(format: "Stress round %d: %@%@ opened in %.0f ms, footprint %@ MB", cycle, tab,
                                    tab == "Кнопки" ? (mouse ? " (мышь)" : " (клавиатура)") : "", took, Self.footprintMB()), "stress")  // no-l10n
                    MainActor.assumeIsolated { SettingsWindow.shared.close() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { settings() } }
                }
            }
            settings()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                Log.info("Stress test start: footprint \(Self.footprintMB()) MB", "stress")
                round()
            }
        }
    }

    private static let stressPages: [(String, Bool)] = [("Кнопки", false), ("Кнопки", true), ("Батарея", false), ("Прокрутка", false), ("Мышь", false), ("Общие", false)]  // no-l10n

    /// The memory footprint, as Activity Monitor shows it.
    static func footprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? String(format: "%.1f", Double(info.phys_footprint) / 1_048_576) : "?"
    }

    @MainActor @objc func openSettings() {
        SettingsWindow.shared.show()
    }

    @MainActor @objc func reportBug() {
        BugReport.compose()
    }
}
