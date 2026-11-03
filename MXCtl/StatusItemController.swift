import AppKit
import SwiftUI

/// Whether the menu bar icon is shown: the "Значок в строке меню" switch in the panel. The state is
/// the status item's own (AppKit saves it per app); it is also off after ⌘-dragging the icon out.
@MainActor
final class MenuBarIcon: ObservableObject {
    static let shared = MenuBarIcon()

    fileprivate weak var statusItem: NSStatusItem?
    private var observation: NSKeyValueObservation?

    @Published var isShown = true {
        didSet {
            guard let statusItem, statusItem.isVisible != isShown else { return }
            statusItem.isVisible = isShown
            Log.info("Menu bar icon \(isShown ? "shown" : "hidden")")
        }
    }

    fileprivate func attach(_ item: NSStatusItem) {
        statusItem = item
        isShown = item.isVisible
        observation = item.observe(\.isVisible) { item, _ in
            Task { @MainActor in
                if MenuBarIcon.shared.isShown != item.isVisible { MenuBarIcon.shared.isShown = item.isVisible }
            }
        }
    }
}

/// The menu bar icon: left click opens the panel, right click a small menu ending with "Завершить".
///
/// Made by hand rather than with SwiftUI's `MenuBarExtra`: when the icon is turned off in System
/// Settings → Menu Bar, a `MenuBarExtra`-only app quits right after launch, and its keys stop
/// working. An `NSStatusItem` just stays hidden; opening the app again (Spotlight, Finder) then
/// shows the panel at the top right of the screen instead.
///
/// The panel is a borderless window with a menu material, not an `NSPopover`: on macOS 26 the
/// popover's glass took ~97 MB of graphics memory while open (132 MB total vs 27 MB with this;
/// measured with `footprint` during `--panel-test`). It is built once and kept, so it opens
/// without building anything.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let content: () -> AnyView
    private let menuItems: () -> [NSMenuItem]
    private let quitTitle: String
    private var panel: MenuPanel?
    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?
    private var visibilityObservation: NSKeyValueObservation?

    /// `menuItems` are built on every right click (so their checkmarks are current).
    init(symbol: String, title: String, content: @escaping () -> AnyView, menuItems: @escaping () -> [NSMenuItem] = { [] }) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.content = content
        self.menuItems = menuItems
        quitTitle = String(localized: "Завершить \(title)")
        super.init()
        statusItem.behavior = .removalAllowed
        MenuBarIcon.shared.attach(statusItem)
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Built ahead (the first build took ~150 ms, a visible jerk on the first opening).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { _ = self?.makePanelIfNeeded() }
        }
        // Hiding the icon (the switch in the panel itself, or ⌘-dragging it out) closes the panel
        // with it, as in other menu bar apps.
        visibilityObservation = statusItem.observe(\.isVisible) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !item.isVisible, self.isPanelShown else { return }
                self.closePanel()
                Log.info("Panel closed: menu bar icon hidden")
            }
        }
    }

    var isPanelShown: Bool { panel?.isVisible == true }

    /// Under the icon, or at the top right of the screen when the icon is hidden.
    func showPanel() {
        let panel = makePanelIfNeeded()
        panel.fitContent()
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin: NSPoint
        if isIconVisible, let button = statusItem.button, let window = button.window {
            let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: icon.minX, y: icon.minY - 6 - size.height)
        } else {
            origin = NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12)
        }
        // Inside the screen.
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(origin)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        watchForClose()
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                Memory.giveBackSoon()
            }
        })
    }

    /// A click anywhere else, Esc, or another Space closes it, like a menu.
    private func watchForClose() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.closePanel(); return nil } // Esc
                    return event
                }
                // A click in another of our windows (the icon toggles by itself).
                if event.window !== self.panel && event.window !== self.statusItem.button?.window { self.closePanel() }
                return event
            }
        }) { monitors.append(local) }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func makePanelIfNeeded() -> MenuPanel {
        if let panel { return panel }
        let panel = MenuPanel(content: content())
        self.panel = panel
        return panel
    }

    /// Hidden with the switch, in System Settings → Menu Bar, or pushed out by a full menu bar.
    private var isIconVisible: Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window else { return false }
        return window.occlusionState.contains(.visible) && window.frame.maxY > 0
    }

    /// `--panel-test`: opens and closes the panel a few times and logs how long the main thread
    /// stalled while it opened (a stall = a jerky opening).
    func runPanelTest(rounds: Int = 6) {
        var round = 0
        func next() {
            guard round < rounds else { return }
            round += 1
            let start = CACurrentMediaTime()
            var last = start
            var longest = 0.0
            var late = 0
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                let now = CACurrentMediaTime()
                longest = max(longest, now - last)
                if now - last > 0.025 { late += 1 }
                last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            showPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                timer.invalidate()
                Log.info(String(format: "Panel test %d: longest stall %.1f ms, %d over 25 ms", round, longest * 1000, late), "panel")
                self.closePanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
            }
        }
        next()
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closePanel()
            showMenu()
        } else if isPanelShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let extra = menuItems()
        extra.forEach(menu.addItem)
        if !extra.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem(title: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Attached only for this click, so a left click still opens the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}

/// The panel window: borderless, menu material, rounded, sized to its SwiftUI content.
private final class MenuPanel: NSPanel {
    private let host: NSHostingView<AnyView>

    init(content: AnyView) {
        host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        contentView = effect
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        host.layoutSubtreeIfNeeded()
    }

    /// Keyboard for the toggles and buttons (a borderless window cannot be key by default).
    override var canBecomeKey: Bool { true }

    /// The content may have grown (a warning, a device) since the last opening.
    func fitContent() {
        let size = host.fittingSize
        if size != frame.size { setContentSize(size) }
    }
}

/// "Значок в строке меню" for the panel. Off: the app keeps working; open it again from
/// Spotlight or Finder to get the panel back.
struct MenuBarIconToggle: View {
    @ObservedObject private var icon = MenuBarIcon.shared

    var body: some View {
        Toggle("Значок в строке меню", isOn: $icon.isShown)
            .help("Без значка приложение продолжает работать; панель открывается повторным запуском из Spotlight или Finder")
    }
}
