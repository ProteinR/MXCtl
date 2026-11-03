import AppKit
import SwiftUI

/// Settings → Батарея: each device's charge now, when it was last full, how fast it drains, the
/// discharge graph from the journal, the low-battery notifications, and the latest journal events
/// (Mac sleep/wake, reconnects, the devices' own messages) to find patterns in.
struct BatteryTab: View {
    @EnvironmentObject private var manager: DeviceManager
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var journal = EventJournal.shared
    @State private var days = 1
    @State private var showEvents = false

    private var journalSummary: String {
        let today = journal.recent.filter { Calendar.current.isDateInToday($0.time) }.count
        return String(localized: "Сегодня событий: \(today)")
    }

    private var offlineDevices: [String] {
        let connected = Set(manager.devices.map(\.name))
        return journal.lastBattery.keys.filter { !connected.contains($0) }.sorted()
    }

    var body: some View {
        Form {
            Section {
                Picker("Период", selection: $days) {
                    Text("24 часа").tag(1)
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                .pickerStyle(.segmented)
            }
            ForEach(manager.devices) { device in
                ConnectedBatterySection(device: device, days: days)
            }
            // Devices with history that are not connected now (the keyboard on its cable after a
            // wake, …): the graph stays, with the last known charge.
            ForEach(offlineDevices, id: \.self) { name in
                let last = journal.lastBattery[name]
                BatterySection(name: name, battery: last?.percent, charging: last?.charging ?? false,
                               lastSeen: last?.time, days: days)
            }
            let keyboards = manager.devices.filter(\.hasBacklight)
            if !keyboards.isEmpty {
                Section("Подсветка клавиатуры") {
                    ForEach(keyboards) { device in
                        BacklightRow(device: device)
                    }
                    Toggle("Выключать подсветку, когда Mac засыпает или гаснет экран", isOn: $store.config.backlightOffOnSleep)
                    Text("При пробуждении подсветка включается снова с прежними настройками. Момент, когда загораются светодиоды, клавиатура не сообщает; её настройки и изменения пишутся в журнал при подключении, пробуждении и раз в 10 минут.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Уведомление о разрядке") {
                Stepper("Предупредить при \(store.config.batteryWarning)%", value: $store.config.batteryWarning, in: 5...50, step: 5)
                Stepper("Ещё раз при \(store.config.batteryCritical)%", value: $store.config.batteryCritical, in: 1...20)
                Text("Уведомление macOS, видно и со скрытой иконкой. Каждое — один раз за разряд; на зарядке не приходит.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Пример: 15%") {
                        BatteryAlerts.notify(title: BatteryAlerts.title(device: "MX Master 3S", percent: 15), body: BatteryAlerts.body(.warning), level: .warning)
                    }
                    Button("Пример: 5%") {
                        BatteryAlerts.notify(title: BatteryAlerts.title(device: "MX Master 3S", percent: 5), body: BatteryAlerts.body(.critical), level: .critical)
                    }
                }
            }
            Section {
                CollapsibleSection(title: "Журнал событий", icon: "list.bullet.rectangle", summary: journalSummary,
                                   isExpanded: $showEvents) {
                    let recent = journal.recent.suffix(40).reversed()
                    ForEach(Array(recent)) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.time.formatted(.dateTime.day().month(.abbreviated).hour().minute().second()))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Text([event.device, event.title].compactMap { $0 }.joined(separator: ": "))
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
                HStack {
                    Text("Сон и пробуждение Mac, блокировка экрана, подключения и сообщения самих устройств — чтобы потом найти, например, почему ночью загорается подсветка.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Файл журнала") { NSWorkspace.shared.activateFileViewerSelecting([EventJournal.fileURL]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectedBatterySection: View {
    @ObservedObject var device: LogiDevice
    let days: Int

    var body: some View {
        BatterySection(name: device.name, battery: device.battery, charging: device.charging, lastSeen: nil, days: days)
    }
}

/// One device's charge and graph; `lastSeen` is set when it is not connected (the charge is then
/// the last one in the journal, not a reading now).
private struct BatterySection: View {
    let name: String
    let battery: Int?
    let charging: Bool
    let lastSeen: Date?
    let days: Int
    @ObservedObject private var journal = EventJournal.shared

    var body: some View {
        let since = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let history = journal.batteryHistory(device: name, since: since)
        Section(name) {
            HStack(alignment: .firstTextBaseline) {
                Text(battery.map { "\($0)%" } ?? "—")
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                    .foregroundStyle(lastSeen == nil ? .primary : .secondary)
                if let lastSeen {
                    Text("не подключена, замер \(lastSeen.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                } else if charging {
                    Label("заряжается", systemImage: "bolt.fill").foregroundStyle(.green)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(lastFullText).font(.callout)
                    if let rate = drainPerDay(history) {
                        Text(String(format: String(localized: "Расход ~%.1f%% в день"), rate) + (remainingDays(rate).map { String(localized: ", хватит на ~\($0) дн.") } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if history.count >= 2 {
                BatteryChart(segments: BatterySegment.segments(readings: readings(history), from: since, to: lastSeen ?? Date()),
                             since: since, days: days)
            } else {
                Text("График появится, когда накопятся замеры: заряд меняется медленно, нужно день-два.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The journal's readings plus the current one (the last bar is "now").
    private func readings(_ history: [JournalEvent]) -> [(time: Date, percent: Int, charging: Bool)] {
        var result = history.compactMap { event in event.percent.map { (event.time, $0, event.charging ?? false) } }
        // The last bar is "now" only while connected; otherwise the graph ends at the last reading.
        if lastSeen == nil, let now = battery { result.append((Date(), now, charging)) }
        return result
    }

    private var lastFullText: String {
        guard let date = journal.lastFullCharge[name] else { return String(localized: "Полная зарядка: ещё не было") }
        let relative = date.formatted(.relative(presentation: .named))
        return String(localized: "Полная зарядка: \(date.formatted(.dateTime.day().month(.wide).hour().minute())) (\(relative))")
    }

    /// Percent per day over the current discharge (since the last charging stopped).
    private func drainPerDay(_ history: [JournalEvent]) -> Double? {
        let discharge = Array(history.reversed().prefix { $0.charging == false }.reversed())
        guard let first = discharge.first, let last = discharge.last, last.time.timeIntervalSince(first.time) > 6 * 3600,
              let start = first.percent, let end = last.percent, start > end else { return nil }
        return Double(start - end) / (last.time.timeIntervalSince(first.time) / 86400)
    }

    private func remainingDays(_ rate: Double) -> Int? {
        guard let battery, rate > 0 else { return nil }
        return Int((Double(battery) / rate).rounded())
    }
}

/// The charge as a step line in its state's colour (charging green, below 20 % red, else the
/// accent) over a pale fill of the same colour, so the eye catches the line first. Drawn by AppKit
/// into an image: any Swift Charts chart or SwiftUI `Canvas` with something drawn in it took
/// ~100 MB of graphics memory for a moment each time the page appeared (157 MB instead of 51)
/// and kept ~5 MB more; the image costs nothing extra.
private struct BatteryChart: View {
    let segments: [BatterySegment]
    let since: Date
    let days: Int
    @Environment(\.colorScheme) private var colorScheme

    private static let height: CGFloat = 160
    private static let labelWidth: CGFloat = 34
    private static let labelHeight: CGFloat = 18

    static func color(_ state: BatteryBar.State) -> Color {
        Color(nsColor: nsColor(state))
    }

    static func nsColor(_ state: BatteryBar.State) -> NSColor {
        switch state {
        case .normal: return .controlAccentColor
        case .charging: return .systemGreen
        case .low: return .systemRed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                Image(nsImage: image(width: max(geometry.size.width, 100)))
            }
            .frame(height: Self.height)
            HStack(spacing: 14) {
                ForEach([BatteryBar.State.normal, .charging, .low], id: \.self) { state in
                    HStack(spacing: 5) {
                        Capsule().fill(Self.color(state)).frame(width: 14, height: 3)
                        Text(state.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("График заряда")
    }

    private func image(width: CGFloat) -> NSImage {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let segments = segments, since = since, days = days
        return NSImage(size: NSSize(width: width, height: Self.height), flipped: true) { rect in
            (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                Self.draw(segments: segments, since: since, days: days, in: rect)
            }
            return true
        }
    }

    private static func draw(segments: [BatterySegment], since: Date, days: Int, in rect: NSRect) {
        let now = Date()
        let plot = NSRect(x: 0, y: 4, width: rect.width - labelWidth, height: rect.height - labelHeight - 4)
        let span = max(now.timeIntervalSince(since), 1)
        func x(_ date: Date) -> CGFloat { plot.minX + CGFloat(date.timeIntervalSince(since) / span) * plot.width }
        func y(_ percent: Int) -> CGFloat { plot.maxY - CGFloat(percent) / 100 * plot.height }
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        func line(_ from: NSPoint, _ to: NSPoint) {
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = 0.5
            NSColor.separatorColor.setStroke()
            path.stroke()
        }

        // Charge grid and its labels on the right.
        for percent in [0, 50, 100] {
            line(NSPoint(x: plot.minX, y: y(percent)), NSPoint(x: plot.maxX, y: y(percent)))
            let text = "\(percent)%" as NSString
            let size = text.size(withAttributes: label)
            text.draw(at: NSPoint(x: plot.maxX + 6, y: y(percent) - size.height / 2), withAttributes: label)
        }
        // Time grid: every 4 hours for a day, else every 1/5/15 days, at local midnight.
        for tick in ticks(since: since, now: now, days: days) {
            line(NSPoint(x: x(tick), y: plot.minY), NSPoint(x: x(tick), y: plot.maxY))
            let text = (days == 1 ? tick.formatted(.dateTime.hour()) : tick.formatted(.dateTime.day().month(.abbreviated))) as NSString
            text.draw(at: NSPoint(x: x(tick) + 2, y: plot.maxY + 3), withAttributes: label)
        }
        // Pale fill first, then the bright line over all of it.
        for segment in segments {
            nsColor(segment.state).withAlphaComponent(0.16).setFill()
            NSRect(x: x(segment.start), y: y(segment.percent),
                   width: x(segment.end) - x(segment.start), height: plot.maxY - y(segment.percent)).fill()
        }
        for segment in segments {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x(segment.start), y: y(segment.percent)))
            path.line(to: NSPoint(x: x(segment.end), y: y(segment.percent)))
            if let next = segment.next { path.line(to: NSPoint(x: x(segment.end), y: y(next))) }
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            nsColor(segment.state).setStroke()
            path.stroke()
        }
    }

    private static func ticks(since: Date, now: Date, days: Int) -> [Date] {
        let calendar = Calendar.current
        var ticks: [Date] = []
        var tick = calendar.startOfDay(for: since)
        let step = days <= 7 ? 1 : days <= 30 ? 5 : 15
        while tick <= now {
            if tick >= since { ticks.append(tick) }
            tick = days == 1 ? tick.addingTimeInterval(4 * 3600)
                : calendar.date(byAdding: .day, value: step, to: tick) ?? now.addingTimeInterval(1)
        }
        return ticks
    }
}

private struct BacklightRow: View {
    @ObservedObject var device: LogiDevice

    var body: some View {
        HStack {
            Image(systemName: device.backlight?.enabled == true ? "light.max" : "light.min")
                .foregroundStyle(device.backlight?.enabled == true ? Color.accentColor : .secondary)
            Text(device.name)
            Spacer()
            Text(device.backlight.map { $0.summary.prefix(1).uppercased() + $0.summary.dropFirst() } ?? "—")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
