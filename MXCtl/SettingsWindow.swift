import AppKit
import SwiftUI

/// The settings window. Made on open and dropped on close, so it costs no memory while hidden.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    /// The page and device a newly made window opens on (`--stress-test` goes through every tab).
    private(set) static var startTab: String?
    private(set) static var startOnMouse = CommandLine.arguments.contains("mouse")

    func show(tab: String? = nil, mouse: Bool? = nil) {
        if let tab { Self.startTab = tab }
        if let mouse { Self.startOnMouse = mouse }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(DeviceManager.shared)
                .environmentObject(ConfigStore.shared))
            // The window does not follow the content's size: measuring the whole list for it on
            // every scroll frame made scrolling jerky (seen in Time Profiler).
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "MXCtl — настройки")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            // One size for every tab (as System Settings): long pages scroll inside. The size the
            // owner drags it to is kept between openings.
            if !window.setFrameUsingName(Self.frameName) {
                window.setContentSize(NSSize(width: 620, height: 720))
                window.center()
            }
            window.setFrameAutosaveName(Self.frameName)
            Self.keepOnScreen(window)
            self.window = window
        }
        // A menu bar app may be refused activation (macOS 14+ treats `activate()` as a request)
        // and the window then opened behind other apps: force it.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private static let frameName = "MXCtlSettings"

    /// The whole window inside the screen's visible part (no menu bar, no Dock): smaller if it does
    /// not fit (another screen, a saved size from a bigger one), moved in if it sticks out.
    private static func keepOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    /// `--settings-scroll-test [battery]`: opens the button list unfolded (or the battery page with
    /// its charts) and scrolls it up and down for 10 s, then logs how evenly the main thread kept
    /// up (a stalled frame = a jerk on screen).
    func runScrollTest() {
        show()
        // The devices take a couple of seconds to come in and fill the list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let scrollView = self.window?.contentView.flatMap(Self.tallestScrollView) else {
                Log.error("Scroll test: no scroll view", "settings")
                return
            }
            let clip = scrollView.contentView
            let range = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let start = CACurrentMediaTime()
            var last = start
            var ticks = 0, late = 0
            var longest = 0.0
            Log.info("Scroll test: \(Int(range)) pt to scroll", "settings")
            Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { timer in
                let now = CACurrentMediaTime()
                let gap = now - last
                last = now
                ticks += 1
                longest = max(longest, gap)
                if gap > 0.025 { late += 1 }
                let phase = (now - start) / 2.5 * .pi
                clip.scroll(to: NSPoint(x: 0, y: range * (1 - cos(phase)) / 2))
                scrollView.reflectScrolledClipView(clip)
                if now - start > 10 {
                    timer.invalidate()
                    Log.info(String(format: "Scroll test: %d ticks, longest %.1f ms, %d over 25 ms", ticks, longest * 1000, late), "settings")
                }
            }
        }
    }

    private static func tallestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var stack = [view]
        while let current = stack.popLast() {
            if let scroll = current as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) {
                best = scroll
            }
            stack.append(contentsOf: current.subviews)
        }
        return best
    }

    /// Lays out and draws the window at once (for timing how long a page takes to open).
    func layoutNow() {
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        DeviceManager.shared.stopLearning()
        window?.contentViewController = nil
        window = nil
        Memory.giveBackSoon()
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case buttons = "Кнопки", scroll = "Прокрутка", mouse = "Мышь", battery = "Батарея", general = "Общие"  // no-l10n
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .buttons: return "Кнопки"
        case .scroll: return "Прокрутка"
        case .mouse: return "Мышь"
        case .battery: return "Батарея"
        case .general: return "Общие"
        }
    }
}

/// Tabs are a segmented control above the page, not a `TabView`: the AppKit tab view asked every
/// page for its ideal size, which measured the whole button list on every scroll frame (Time
/// Profiler: `AppKitTabView._overrideLayoutTraits`) and made scrolling jerky.
struct SettingsView: View {
    @State private var tab = SettingsWindow.startTab.flatMap(SettingsTab.init(rawValue:))
        ?? (CommandLine.arguments.contains("battery") ? SettingsTab.battery : .buttons)

    var body: some View {
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .frame(minWidth: 560, minHeight: 360)
            .toggleStyle(LightSwitchStyle())
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .buttons: ButtonsTab(openScrollTab: { tab = .scroll })
        case .scroll: ScrollTab()
        case .mouse: MouseTab()
        case .battery: BatteryTab()
        case .general: GeneralTab()
        }
    }
}

// MARK: - Buttons

/// As in Logi Options+: the device picture with a dot on every button; a click on a dot opens
/// that button's action below. The full list stays available, folded, under the picture.
private struct ButtonsTab: View {
    @EnvironmentObject private var manager: DeviceManager
    @EnvironmentObject private var store: ConfigStore
    let openScrollTab: () -> Void
    @State private var deviceID: String?
    @State private var selected: DeviceArt.Marker.Target?
    /// Open for `--settings-scroll-test`, so there is a long list to scroll.
    @State private var showList = CommandLine.arguments.contains("--settings-scroll-test")

    var body: some View {
        let device = manager.devices.first { $0.id == deviceID } ?? manager.devices.first
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if manager.devices.count > 1 {
                        Picker("", selection: Binding(get: { device?.id }, set: { deviceID = $0; selected = nil })) {
                            ForEach(manager.devices) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Spacer()
                    Button(manager.isLearning ? "Нажмите клавишу или кнопку…" : "Определить клавишу") {
                        manager.isLearning ? manager.stopLearning() : manager.startLearning()
                    }
                }
                if let device {
                    // A new picture per device (its own @State), not the previous device's.
                    DevicePicture(device: device, selected: $selected)
                        .id(device.id)
                    editor(device)
                    CollapsibleSection(title: "Все кнопки списком", icon: "list.bullet", summary: summary(device),
                                       isExpanded: $showList) {
                        DeviceList(device: device, highlighted: manager.learned?.cid)
                            .padding(.top, 8)
                    }
                } else {
                    Text("Устройства Logitech не подключены").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                let offline = offlineKeys
                if !offline.isEmpty {
                    GroupBox("Не подключены сейчас") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(offline, id: \.self) { cid in
                                ControlRow(cid: cid, hasSwipes: store.binding(cid).usesSwipes, highlighted: false)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            if SettingsWindow.startOnMouse { deviceID = manager.devices.first(where: \.isMouse)?.id }
        }
        .onChange(of: manager.learned?.cid) { _, cid in
            // "Определить клавишу": show the key that was pressed, on its device.
            guard let cid, let learned = manager.learned else { return }
            if let owner = manager.devices.first(where: { $0.name == learned.device }) { deviceID = owner.id }
            selected = .control(cid)
        }
    }

    @ViewBuilder
    private func editor(_ device: LogiDevice) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                switch selected {
                case .control(let cid)?:
                    if let control = device.divertable.first(where: { $0.cid == cid }) {
                        ControlRow(cid: cid, hasSwipes: control.hasRawXY, highlighted: true)
                    } else {
                        Text("\(KnownControl.name(cid)): эту кнопку обрабатывает само устройство, переназначить нельзя.")
                            .foregroundStyle(.secondary)
                    }
                    Text("Цветом выделены кнопки, которые вы изменили. «По умолчанию» — то, что кнопка делала у Logitech из коробки.")
                        .font(.caption).foregroundStyle(.secondary)
                case .thumbWheel?:
                    HStack {
                        Text("Боковое колесо — горизонтальная прокрутка.")
                        Spacer()
                        Button("Настроить прокрутку…", action: openScrollTab)
                    }
                case nil:
                    Text("Нажмите на точку на изображении, чтобы настроить кнопку.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Изменено: F8 (скриншот)", or that all are by default.
    private func summary(_ device: LogiDevice) -> String {
        let changed = device.divertable.filter { KnownControl.isChanged($0.cid, store.binding($0.cid)) }.map { KnownControl.name($0.cid) }
        return changed.isEmpty ? String(localized: "\(device.divertable.count) кнопок, все по умолчанию")
            : String(localized: "Изменено: \(changed.joined(separator: ", "))")
    }

    /// Controls with a binding in the config that no connected device has.
    private var offlineKeys: [UInt16] {
        let present = Set(manager.devices.flatMap { $0.controls.map(\.cid) })
        return store.config.bindings.keys.compactMap { UInt16($0, radix: 16) }
            .filter { !present.contains($0) && KnownControl.isChanged($0, store.binding($0)) }
            .sorted()
    }
}

/// The picture with the dots: white = the device does it itself, coloured = MXCtl has an action,
/// ringed = selected. Loaded on appear and dropped with the settings window.
private struct DevicePicture: View {
    @ObservedObject var device: LogiDevice
    @Binding var selected: DeviceArt.Marker.Target?
    @EnvironmentObject private var store: ConfigStore
    @State private var art: DeviceArt?
    @State private var hovered: DeviceArt.Marker.Target?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let art {
                let aspect = art.image.size.width / max(art.image.size.height, 1)
                Image(nsImage: colorScheme == .dark ? art.darkImage : art.image)
                    .resizable()
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            ForEach(art.markers) { marker in
                                // Keyboard: a frame around the key. Mouse: a dot (its buttons are
                                // odd shapes; frames looked crude on it).
                                if aspect < 1 {
                                    dot(marker, in: geometry.size)
                                } else {
                                    frame(marker, in: geometry.size)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: aspect < 1 ? 380 : 260)
                    .frame(maxWidth: .infinity)
            } else {
                Text(device.name).font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .onAppear { art = DeviceArt.load(productID: device.productID) }
    }

    private func isChanged(_ marker: DeviceArt.Marker) -> Bool {
        if case .control(let cid) = marker.target { return KnownControl.isChanged(cid, store.binding(cid)) }
        return false
    }

    /// A white dot with a soft halo; accent when changed; it grows a ring on hover and fills with
    /// the accent and a thicker ring when selected.
    private func dot(_ marker: DeviceArt.Marker, in size: CGSize) -> some View {
        let isSelected = selected == marker.target
        let isHovered = hovered == marker.target
        let color: Color = isSelected || isChanged(marker) ? .accentColor : .white
        return ZStack {
            Circle()
                .fill(color.opacity(isSelected ? 0.3 : isHovered ? 0.22 : 0))
                .frame(width: 30, height: 30)
            Circle()
                .strokeBorder(color, lineWidth: isSelected ? 2.5 : 1.5)
                .frame(width: 26, height: 26)
                .opacity(isSelected || isHovered ? 1 : 0)
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        }
        .scaleEffect(isHovered && !isSelected ? 1.08 : 1)
        .contentShape(Circle().size(width: 30, height: 30))
        .onHover { inside in
            if inside { hovered = marker.target } else if hovered == marker.target { hovered = nil }
        }
        .onTapGesture { selected = marker.target }
        .help(title(marker))
        .position(x: marker.x * size.width, y: marker.y * size.height)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    /// White outline = the key's default, accent outline = changed; brighter on hover, filled and
    /// thicker when selected.
    private func frame(_ marker: DeviceArt.Marker, in size: CGSize) -> some View {
        let isSelected = selected == marker.target
        let isHovered = hovered == marker.target
        let color: Color = isSelected || isChanged(marker) ? .accentColor : .white
        let shape = RoundedRectangle(cornerRadius: min(marker.width * size.width, marker.height * size.height) * 0.22, style: .continuous)
        return shape
            .fill(color.opacity(isSelected ? 0.28 : isHovered ? 0.18 : 0.001))
            .overlay(shape.strokeBorder(color.opacity(isSelected || isHovered ? 1 : 0.75), lineWidth: isSelected ? 3 : isHovered ? 2.5 : 1.5))
            .shadow(color: .black.opacity(0.45), radius: 2)
            .frame(width: marker.width * size.width, height: marker.height * size.height)
            .contentShape(shape)
            .onHover { inside in
                if inside { hovered = marker.target } else if hovered == marker.target { hovered = nil }
            }
            .onTapGesture { selected = marker.target }
            .help(title(marker))
            .position(x: marker.x * size.width, y: marker.y * size.height)
            .animation(.easeOut(duration: 0.12), value: isSelected)
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private func title(_ marker: DeviceArt.Marker) -> String {
        switch marker.target {
        case .control(let cid):
            let action = store.binding(cid)
            return KnownControl.name(cid) + (KnownControl.isChanged(cid, action) ? " — \(action.click.title)" : "")
        case .thumbWheel:
            return String(localized: "Боковое колесо")
        }
    }
}

/// The same controls as a list (folded under the picture).
private struct DeviceList: View {
    @ObservedObject var device: LogiDevice
    let highlighted: UInt16?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(device.divertable, id: \.cid) { control in
                ControlRow(cid: control.cid, hasSwipes: control.hasRawXY, highlighted: control.cid == highlighted)
                Divider()
            }
            let fixed = device.controls.filter { !$0.isDivertable && !$0.isVirtual && KnownControl.names[$0.cid] != nil }
            if !fixed.isEmpty {
                Text("Нельзя переназначить (их обрабатывает само устройство): \(fixed.map { KnownControl.name($0.cid) }.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ControlRow: View {
    @EnvironmentObject private var store: ConfigStore
    let cid: UInt16
    /// The control reports movement while held, so it can have swipes.
    let hasSwipes: Bool
    let highlighted: Bool
    @State private var swipesOpen = false

    private var factory: ButtonBinding { KnownControl.factory(cid) }

    /// Swipes are shown for the gesture button, for a control that already has them, or on request.
    private var showsSwipes: Bool {
        hasSwipes && (cid == KnownControl.gestureButton || store.binding(cid).usesSwipes || swipesOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(KnownControl.name(cid))
                        .fontWeight(highlighted ? .bold : .regular)
                        .foregroundStyle(highlighted ? Color.accentColor : .primary)
                        .help(String(format: "0x%04X", cid))
                    if hasSwipes && !showsSwipes {
                        Button("Добавить жесты") { swipesOpen = true }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                Spacer()
                ActionEditor(action: binding(\.click), defaultAction: factory.click, defaultTitle: KnownControl.defaultTitle(cid))
            }
            if showsSwipes {
                ForEach(SwipeDirection.allCases, id: \.self) { direction in
                    HStack(alignment: .top) {
                        Text(direction.title).foregroundStyle(.secondary).padding(.leading, 16)
                        Spacer()
                        ActionEditor(action: binding(path(direction)), defaultAction: factory.swipe(direction),
                                     defaultTitle: Self.defaultTitle(factory.swipe(direction)))
                    }
                }
            }
        }
    }

    private static func defaultTitle(_ action: Action) -> String {
        let name = action == .native ? String(localized: "Ничего") : action.title
        return String(localized: "\(name) — по умолчанию")
    }

    private func path(_ direction: SwipeDirection) -> WritableKeyPath<ButtonBinding, Action> {
        switch direction {
        case .up: return \.up
        case .down: return \.down
        case .left: return \.left
        case .right: return \.right
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ButtonBinding, Action>) -> Binding<Action> {
        Binding(get: { store.binding(cid)[keyPath: keyPath] },
                set: {
                    var value = store.binding(cid)
                    value[keyPath: keyPath] = $0
                    store.setBinding(value, for: cid)
                })
    }
}

// MARK: - Scrolling

private struct ScrollTab: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        Form {
            Section("Колесо мыши (трекпад не затрагивается)") {
                Toggle("Плавная прокрутка", isOn: $store.config.scroll.smooth)
                Toggle("    по вертикали", isOn: $store.config.scroll.smoothVertical).disabled(!store.config.scroll.smooth)
                Toggle("    по горизонтали (боковое колесо)", isOn: $store.config.scroll.smoothHorizontal).disabled(!store.config.scroll.smooth)
                Toggle("Инверсия по вертикали", isOn: $store.config.scroll.reverseVertical)
                Toggle("Инверсия по горизонтали", isOn: $store.config.scroll.reverseHorizontal)
            }
            Section("Плавность") {
                slider("Шаг", "Минимальное расстояние одного щелчка колеса", value: $store.config.scroll.step, range: 1...150, format: "%.0f")
                slider("Скорость", "Множитель расстояния", value: $store.config.scroll.speed, range: 0.5...5, format: "%.2f")
                slider("Продолжительность", "Длина анимации: больше — дольше докатывается", value: $store.config.scroll.duration, range: 0...5, format: "%.2f")
                Button("По умолчанию (шаг 65, скорость 1.8)") {
                    store.config.scroll = ScrollSettings()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: LocalizedStringKey, _ help: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Mouse

private struct MouseTab: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var manager: DeviceManager

    var body: some View {
        Form {
            Section("SmartShift (колесо само переходит в свободное вращение)") {
                Toggle("Задавать порог при подключении мыши", isOn: $store.config.smartShift.enabled)
                HStack {
                    Text("Порог")
                    Slider(value: Binding(get: { Double(store.config.smartShift.threshold ?? 10) },
                                          set: { store.config.smartShift.threshold = Int($0.rounded()) }),
                           in: 1...255)
                    Text(store.config.smartShift.threshold.map(String.init) ?? "—")
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .disabled(!store.config.smartShift.enabled)
                Text("Меньше — колесо раскручивается легче; 255 — всегда по щелчкам. Кнопка под колесом переключает режим вручную.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(manager.devices.filter { $0.smartShift != nil }) { device in
                    if let state = device.smartShift {
                        Text("\(device.name): сейчас порог \(state.threshold)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Жесты кнопки под большим пальцем") {
                HStack {
                    Text("Чувствительность свайпа")
                    Slider(value: Binding(get: { Double(store.config.swipeThreshold) },
                                          set: { store.config.swipeThreshold = Int($0.rounded()) }),
                           in: 20...200)
                    Text("\(store.config.swipeThreshold)").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Text("Насколько сдвинуть мышь с зажатой кнопкой, чтобы это стало свайпом. Меньше — чувствительнее.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        Form {
            Section {
                LanguagePicker()
                LoginItemToggle()
                MenuBarIconToggle()
            }
            Section("Файл настроек") {
                Text(ConfigStore.fileURL.path)
                    .font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL]) }
                    Button("Перечитать") { store.reload() }
                    Button("Лог") { NSWorkspace.shared.open(Log.fileURL) }
                }
                Text("Настройки можно править и руками: JSON, после правки — «Перечитать».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Обратная связь") {
                Button("Сообщить об ошибке…") { BugReport.compose() }
                Text("Откроется отчёт с шаблоном, версиями, списком устройств и концом лога: скопируйте его и отправьте автору (\(BugReport.address)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// After a window closes, the freed memory stays with the allocator for reuse; this hands it back to
/// macOS so the footprint drops back (measured: 46 MB stayed after the settings window closed).
enum Memory {
    @MainActor
    static func giveBackSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let freed = malloc_zone_pressure_relief(nil, 0)
            Log.debug("Memory given back: \(freed / 1024) KB, footprint now \(AppDelegate.footprintMB()) MB", "memory")
        }
    }
}
