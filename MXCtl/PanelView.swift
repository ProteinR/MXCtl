import SwiftUI

/// The menu bar panel: devices, warnings, the main switches and the way to the settings.
struct PanelView: View {
    @EnvironmentObject private var manager: DeviceManager
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var permissions: Permissions
    @State private var competitors = Competitors.running()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("MXCtl").font(.headline)
                Text(AppDelegate.appVersion)
                    .font(.caption).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            if !permissions.inputMonitoring {
                warning("Клавиши и кнопки не перехватываются", "Нужен доступ «Мониторинг ввода».",
                        button: "Разрешить…") { permissions.requestInputMonitoring() }
            }
            if !permissions.accessibility {
                warning("Прокрутка и сочетания клавиш не работают", "Нужен доступ «Универсальный доступ».",
                        button: "Разрешить…") { permissions.requestAccessibility() }
            }
            if !competitors.isEmpty {
                warning("Запущено: \(competitors.joined(separator: ", "))",
                        "Они перехватывают те же клавиши и колесо. Закройте их, пока работает MXCtl.",
                        button: nil, action: {})
            }

            UpdateBanner()

            if manager.devices.isEmpty {
                Text(permissions.inputMonitoring ? "Устройства Logitech не найдены" : "Устройства появятся после разрешения")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(manager.devices) { device in
                DeviceRow(device: device)
            }

            Divider()

            Toggle("Плавная прокрутка", isOn: $store.config.scroll.smooth)
            Toggle("Инверсия колеса", isOn: Binding(
                get: { store.config.scroll.reverseVertical },
                set: {
                    store.config.scroll.reverseVertical = $0
                    store.config.scroll.reverseHorizontal = $0
                }))

            LoginItemToggle()
            MenuBarIconToggle()

            HStack {
                Button("Настройки…") { SettingsWindow.shared.show() }
                Button("Лог") { NSWorkspace.shared.open(Log.fileURL) }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { competitors = Competitors.running() }
    }

    @ViewBuilder
    private func warning(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, button: LocalizedStringKey?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let button { Button(button, action: action) }
        }
    }
}

private struct DeviceRow: View {
    @ObservedObject var device: LogiDevice

    var body: some View {
        HStack {
            Image(systemName: device.isMouse ? "computermouse" : "keyboard")
                .frame(width: 22)
            Text(device.name)
            Spacer()
            if let battery = device.battery {
                Label("\(battery)%", systemImage: device.charging ? "battery.100percent.bolt" : batterySymbol(battery))
                    .labelStyle(.titleAndIcon)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(battery <= 15 ? .red : .secondary)
            }
        }
    }

    private func batterySymbol(_ value: Int) -> String {
        switch value {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
