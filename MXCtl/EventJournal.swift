import AppKit

/// A plain journal of what happens to the Mac and the devices, for the battery history and graph
/// and for finding patterns later (the keyboard backlight lighting up at night: Mac sleep/wake,
/// screen lock, device reconnects and the keyboard's own HID++ messages are all here).
///
/// `~/Library/Application Support/MXCtl/events.jsonl`, one JSON object per line; older than a year
/// is dropped at launch.
struct JournalEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case macSleep, macWake, screensSleep, screensWake, screenLocked, screenUnlocked
        case connected, disconnected, battery, deviceMessage, appStarted, backlight
    }

    var time: Date
    var kind: Kind
    /// The device's name, for device events.
    var device: String?
    var percent: Int?
    var charging: Bool?
    /// Free text: the HID++ message, etc.
    var detail: String?

    var id: String { "\(time.timeIntervalSince1970)-\(kind.rawValue)-\(device ?? "")" }

    var title: String {
        switch kind {
        case .macSleep: return "Mac уснул"
        case .macWake: return "Mac проснулся"
        case .screensSleep: return "Экран погас"
        case .screensWake: return "Экран включился"
        case .screenLocked: return "Экран заблокирован"
        case .screenUnlocked: return "Экран разблокирован"
        case .connected: return "Подключено"
        case .disconnected: return "Отключено"
        case .battery: return "Заряд \(percent ?? 0)%" + (charging == true ? ", заряжается" : "")
        case .deviceMessage: return "Сообщение устройства: \(detail ?? "")"
        case .appStarted: return "MXCtl запущен"
        case .backlight: return "Подсветка \(detail ?? "")"
        }
    }
}

@MainActor
final class EventJournal: ObservableObject {
    static let shared = EventJournal()

    /// Battery readings of the last year (the graph, the last full charge): ~5000 a year.
    @Published private(set) var battery: [JournalEvent] = []
    /// Other events of the last two days, for the list in Settings → Батарея. The file keeps a
    /// year (~37 000 lines, ~3 MB at ~100 events a day); holding and decoding all of it cost
    /// +11 MB and 120 ms at launch, and every redraw of the battery page went through all of it.
    @Published private(set) var recent: [JournalEvent] = []
    /// The last battery reading and the last full charge of each device (kept apart from
    /// `battery` so they need no scan).
    private(set) var lastBattery: [String: JournalEvent] = [:]
    private(set) var lastFullCharge: [String: Date] = [:]
    /// The last backlight event of each device: a new one is written only when it differs.
    private var lastBacklight: [String: String] = [:]
    /// Events recorded before the file finished loading, added after it.
    private var pending: [JournalEvent]? = []

    nonisolated static let fileURL: URL = ConfigStore.fileURL.deletingLastPathComponent().appendingPathComponent("events.jsonl")
    nonisolated static let recentPeriod: TimeInterval = 2 * 24 * 3600
    /// Reading and writing the file, in order: the load goes first.
    private let io = DispatchQueue(label: "MXCtl.journal", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private init() {
        io.async {
            let started = CACurrentMediaTime()
            let loaded = Self.load()
            let took = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apply(loaded)
                    // Decoding a year of lines leaves freed memory behind: hand it back.
                    Memory.giveBackSoon()
                    Log.debug(String(format: "Journal loaded: %d events kept in memory, in %.0f ms",
                                     self.battery.count + self.recent.count, took), "journal")
                }
            }
        }
    }

    func start() {
        record(JournalEvent(time: Date(), kind: .appStarted))
        let center = NSWorkspace.shared.notificationCenter
        let workspace: [(Notification.Name, JournalEvent.Kind)] = [
            (NSWorkspace.willSleepNotification, .macSleep), (NSWorkspace.didWakeNotification, .macWake),
            (NSWorkspace.screensDidSleepNotification, .screensSleep), (NSWorkspace.screensDidWakeNotification, .screensWake),
        ]
        for (name, kind) in workspace {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { EventJournal.shared.record(JournalEvent(time: Date(), kind: kind)) }
            }
        }
        let distributed = DistributedNotificationCenter.default()
        let lock: [(String, JournalEvent.Kind)] = [("com.apple.screenIsLocked", .screenLocked), ("com.apple.screenIsUnlocked", .screenUnlocked)]
        for (name, kind) in lock {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { EventJournal.shared.record(JournalEvent(time: Date(), kind: kind)) }
            }
        }
    }

    func record(_ event: JournalEvent) {
        pending?.append(event)
        keep(event)
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        let url = Self.fileURL
        io.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// A battery reading, kept only when it differs from the device's last one.
    func recordBattery(device: String, percent: Int, charging: Bool) {
        if let last = lastBattery[device], last.percent == percent, last.charging == charging { return }
        record(JournalEvent(time: Date(), kind: .battery, device: device, percent: percent, charging: charging))
    }

    /// Backlight settings, kept when they differ from the device's last ones.
    func recordBacklight(device: String, config: BacklightConfig, reason: String? = nil) {
        let detail = config.summary + (reason.map { " (\($0))" } ?? "")
        if lastBacklight[device] == detail { return }
        record(JournalEvent(time: Date(), kind: .backlight, device: device, detail: detail))
    }

    // MARK: - Battery history

    func batteryHistory(device: String, since: Date) -> [JournalEvent] {
        // Sorted by time: only the tail since `since`.
        let first = battery.lastIndex { $0.time < since }.map { $0 + 1 } ?? 0
        return battery[first...].filter { $0.device == device }
    }

    /// When a reading means "fully charged": 100 %, or charging stopped at 95 % or more.
    /// Only the moment it gets full: more 100 % readings (reconnects, wakes, charging flag
    /// changes) are the same charge, not a new one.
    nonisolated static func isFullCharge(_ event: JournalEvent, after previous: JournalEvent?) -> Bool {
        let percent = event.percent ?? 0
        if (previous?.percent ?? 0) >= 100 { return false }
        return percent >= 100 || (percent >= 95 && event.charging == false && previous?.charging == true)
    }

    // MARK: - Memory

    /// Adds an event to what is kept in memory.
    private func keep(_ event: JournalEvent) {
        guard let device = event.device else { return keepRecent(event) }
        switch event.kind {
        case .battery:
            if Self.isFullCharge(event, after: lastBattery[device]) { lastFullCharge[device] = event.time }
            lastBattery[device] = event
            battery.append(event)
        case .backlight:
            lastBacklight[device] = event.detail
            keepRecent(event)
        default:
            keepRecent(event)
        }
    }

    private func keepRecent(_ event: JournalEvent) {
        recent.append(event)
        // Drop the old ones now and then (not on every event).
        if recent.count > 400, let first = recent.first, first.time < Date().addingTimeInterval(-Self.recentPeriod) {
            let cutoff = Date().addingTimeInterval(-Self.recentPeriod)
            recent.removeAll { $0.time < cutoff }
        }
    }

    private func apply(_ loaded: [JournalEvent]) {
        let added = pending ?? []
        pending = nil
        battery = []
        recent = []
        lastBattery = [:]
        lastFullCharge = [:]
        lastBacklight = [:]
        let recentCutoff = Date().addingTimeInterval(-Self.recentPeriod)
        for event in loaded {
            if event.kind == .backlight, let device = event.device { lastBacklight[device] = event.detail }
            if event.kind != .battery, event.time < recentCutoff { continue }
            keep(event)
        }
        for event in added { keep(event) }
    }

    // MARK: - File

    /// The events kept in memory: battery and backlight ones of the last year, the rest of the last
    /// two days. The file is mapped, not read into memory, and the other lines are skipped by their
    /// kind and time without decoding (decoding all ~37 000 lines of a year left ~8 MB of freed
    /// memory behind). Lines older than a year are dropped from the file when there are a few
    /// hundred of them (every launch would otherwise rewrite it for one line).
    nonisolated private static func load() -> [JournalEvent] {
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let yearCutoff = Data(isoTime(Date().addingTimeInterval(-365 * 24 * 3600)).utf8)
        let recentCutoff = Data(isoTime(Date().addingTimeInterval(-recentPeriod)).utf8)
        let timeKey = Data(#""time":""#.utf8)
        let kept = [#""kind":"battery""#, #""kind":"backlight""#].map { Data($0.utf8) }
        var loaded: [JournalEvent] = []
        var dropped = 0
        for line in data.split(separator: 0x0A) {
            // Times are written as "2026-10-19T12:27:06Z": compared as text.
            if let key = line.range(of: timeKey), line.endIndex - key.upperBound >= 20 {
                let time = line[key.upperBound..<key.upperBound + 20]
                if time.lexicographicallyPrecedes(yearCutoff) {
                    dropped += 1
                    continue
                }
                if time.lexicographicallyPrecedes(recentCutoff), !kept.contains(where: { line.range(of: $0) != nil }) { continue }
            }
            if let event = try? decoder.decode(JournalEvent.self, from: Data(line)) { loaded.append(event) }
        }
        if dropped >= 500 {
            var text = Data()
            for line in data.split(separator: 0x0A) {
                if let key = line.range(of: timeKey), line.endIndex - key.upperBound >= 20,
                   line[key.upperBound..<key.upperBound + 20].lexicographicallyPrecedes(yearCutoff) { continue }
                text.append(line)
                text.append(0x0A)
            }
            try? text.write(to: fileURL, options: .atomic)
        }
        return loaded
    }

    nonisolated private static func isoTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// One bar of the battery chart (as in iPhone's battery settings): the charge at the end of a time
/// slot, and whether it was charging during it.
struct BatteryBar: Identifiable, Equatable {
    enum State: String, Hashable { case normal = "Разряд", charging = "Зарядка", low = "Ниже 20%" }

    let start: Date
    let percent: Int
    let charging: Bool

    var id: Date { start }
    var state: State { charging ? .charging : percent <= 20 ? .low : .normal }

    /// Slots of `slot` seconds from `from` to `to`, aligned to local midnight. A slot takes the last
    /// reading in it (or carries the one before); charging if it charged at any moment in it.
    /// Slots before the first reading are left out.
    static func bars(readings: [(time: Date, percent: Int, charging: Bool)], from: Date, to: Date,
                     slot: TimeInterval, calendar: Calendar = .current) -> [BatteryBar] {
        let sorted = readings.sorted { $0.time < $1.time }
        guard let first = sorted.first else { return [] }
        let midnight = calendar.startOfDay(for: from)
        func slotStart(_ date: Date) -> Date {
            midnight.addingTimeInterval((date.timeIntervalSince(midnight) / slot).rounded(.down) * slot)
        }
        var start = slotStart(max(from, first.time))
        var index = 0
        var carried: (percent: Int, charging: Bool)?
        // Readings before the first slot only set the starting state.
        while index < sorted.count, sorted[index].time < start {
            carried = (sorted[index].percent, sorted[index].charging)
            index += 1
        }
        var bars: [BatteryBar] = []
        while start < to {
            let end = start.addingTimeInterval(slot)
            var charged = carried?.charging ?? false
            while index < sorted.count, sorted[index].time < end {
                carried = (sorted[index].percent, sorted[index].charging)
                charged = charged || sorted[index].charging
                index += 1
            }
            if let carried { bars.append(BatteryBar(start: start, percent: carried.percent, charging: charged)) }
            start = end
        }
        return bars
    }
}

/// A flat stretch of the battery line: the charge from one reading to the next, in its state's
/// colour (charging green, low red, else the accent). `next` is the following charge, for the
/// vertical step at `end`.
struct BatterySegment: Identifiable, Equatable {
    let start: Date
    let end: Date
    let percent: Int
    let next: Int?
    let state: BatteryBar.State

    var id: Date { start }

    /// Segments from `from` to `to`; the reading before `from` sets where the line starts.
    static func segments(readings: [(time: Date, percent: Int, charging: Bool)], from: Date, to: Date) -> [BatterySegment] {
        let sorted = readings.sorted { $0.time < $1.time }
        var points: [(time: Date, percent: Int, charging: Bool)] = []
        for reading in sorted where reading.time < to {
            if reading.time <= from {
                points = [(from, reading.percent, reading.charging)]
            } else {
                points.append(reading)
            }
        }
        var result: [BatterySegment] = []
        for (index, point) in points.enumerated() {
            let following = index + 1 < points.count ? points[index + 1] : nil
            let end = following?.time ?? to
            guard end > point.time else { continue }
            let state: BatteryBar.State = point.charging ? .charging : point.percent <= 20 ? .low : .normal
            result.append(BatterySegment(start: point.time, end: end, percent: point.percent, next: following?.percent, state: state))
        }
        return result
    }
}
