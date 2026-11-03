import AppKit
import CoreVideo

/// Mouse wheel smoothing and direction (what Mos did). A session event tap takes wheel events
/// (needs Accessibility), reverses them if asked, and replaces a notch by many small "continuous"
/// events posted on every display frame. Trackpad and Magic Mouse events (already continuous, or
/// with a phase) pass untouched.
///
/// Nothing here runs on the main thread: the tap has its own thread and run loop, the frames come
/// from a CVDisplayLink on its own thread (as in Mos). A busy main thread (SwiftUI drawing a
/// window) made the scrolling jerky when both lived there. State shared by the two is under `lock`.
final class SmoothScroll: @unchecked Sendable {
    static let shared = SmoothScroll()

    private let lock = NSLock()
    // Under `lock`:
    private var engine = ScrollEngine()
    /// The last real wheel event: frames are copies of it with new distances.
    private var template: CGEvent?
    private var settings = ScrollSettings()
    private var transition = ScrollEngine.transition(duration: 2.75)
    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var stats = FrameStats()
    private var displayLink: CVDisplayLink?

    // Main thread only:
    private var thread: Thread?
    private var screenObserver: NSObjectProtocol?

    /// Per scroll, for the log: how evenly the frames came.
    private struct FrameStats {
        var frames = 0
        var posted = 0
        var last: CFTimeInterval = 0
        var sum: CFTimeInterval = 0
        var longest: CFTimeInterval = 0
        var late = 0

        mutating func tick(_ now: CFTimeInterval) {
            if last > 0 {
                let gap = now - last
                sum += gap
                longest = max(longest, gap)
                if gap > 0.025 { late += 1 }
            }
            last = now
            frames += 1
        }

        var summary: String {
            let average = frames > 1 ? sum / Double(frames - 1) * 1000 : 0
            return String(format: "%d frames, %d posted, avg %.1f ms, longest %.1f ms, %d over 25 ms",
                          frames, posted, average, longest * 1000, late)
        }
    }

    @MainActor
    func apply(_ settings: ScrollSettings) {
        lock.withLock {
            self.settings = settings
            transition = ScrollEngine.transition(duration: settings.duration)
        }
        if settings.isActive { start() } else { stop() }
    }

    @MainActor
    func start() {
        guard thread == nil else { return }
        let thread = Thread { [self] in runTap() }
        thread.name = "MXCtl scroll tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        makeDisplayLink()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.makeDisplayLink() }
        }
    }

    @MainActor
    func stop() {
        guard thread != nil else { return }
        let (tap, runLoop) = lock.withLock { (self.tap, self.tapRunLoop) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        thread = nil
        if let link = lock.withLock({ () -> CVDisplayLink? in defer { displayLink = nil }; return displayLink }) {
            CVDisplayLinkStop(link)
        }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        lock.withLock {
            self.tap = nil
            tapRunLoop = nil
            engine.reset()
            template = nil
        }
        Log.info("Scroll tap removed", "scroll")
    }

    // MARK: - Tap thread

    private func runTap() {
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<SmoothScroll>.fromOpaque(refcon!).takeUnretainedValue().handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.error("Cannot create the scroll tap (Accessibility permission missing?)", "scroll")
            return
        }
        let runLoop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let settings = lock.withLock {
            self.tap = tap
            tapRunLoop = runLoop
            return self.settings
        }
        Log.info("Scroll tap installed on its own thread (smooth \(settings.smooth), reverse \(settings.reverseVertical)/\(settings.reverseHorizontal))", "scroll")
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.warning("Scroll tap was disabled (\(type.rawValue)), re-enabled", "scroll")
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != ActionRunner.eventMarker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getDoubleValueField(.scrollWheelEventScrollPhase) == 0,
              event.getDoubleValueField(.scrollWheelEventMomentumPhase) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        let settings = lock.withLock { self.settings }
        var dy = Self.usable(event, axis: 1)
        var dx = Self.usable(event, axis: 2)
        if settings.reverseVertical { dy = -dy }
        if settings.reverseHorizontal { dx = -dx }
        let smoothY = settings.smooth && settings.smoothVertical && dy != 0
        let smoothX = settings.smooth && settings.smoothHorizontal && dx != 0

        if !smoothY && !smoothX {
            if settings.reverseVertical { Self.negate(event, axis: 1) }
            if settings.reverseHorizontal { Self.negate(event, axis: 2) }
            return Unmanaged.passUnretained(event)
        }

        let copy = event.copy()
        lock.withLock {
            engine.add(y: smoothY ? ScrollEngine.normalized(dy, step: settings.step) * settings.speed : 0,
                       x: smoothX ? ScrollEngine.normalized(dx, step: settings.step) * settings.speed : 0)
            template = copy
        }
        if let link = lock.withLock({ displayLink }), !CVDisplayLinkIsRunning(link) {
            // Frames at the rate of the screen under the pointer (120 Hz MacBook, 75 Hz monitor):
            // another screen's rate does not line up with this one's and judders.
            var display = CGDirectDisplayID()
            var count: UInt32 = 0
            if CGGetDisplaysWithPoint(event.location, 1, &display, &count) == .success, count > 0,
               CVDisplayLinkGetCurrentCGDisplay(link) != display {
                CVDisplayLinkSetCurrentCGDisplay(link, display)
                Log.debug(String(format: "Display link moved to display %u, %.0f Hz", display, Self.rate(link)), "scroll")
            }
            CVDisplayLinkStart(link)
        }

        // A mixed event: the axis not smoothed goes on as it was (reversed if asked).
        if (dy != 0 && !smoothY) || (dx != 0 && !smoothX) {
            if smoothY { Self.clear(event, axis: 1) } else if settings.reverseVertical { Self.negate(event, axis: 1) }
            if smoothX { Self.clear(event, axis: 2) } else if settings.reverseHorizontal { Self.negate(event, axis: 2) }
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    // MARK: - Frames (display link thread)

    @MainActor
    private func makeDisplayLink() {
        if let old = lock.withLock({ displayLink }) { CVDisplayLinkStop(old) }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
            Log.error("Cannot create the display link", "scroll")
            lock.withLock { displayLink = nil }
            return
        }
        CVDisplayLinkSetOutputHandler(link) { [weak self] link, _, _, _, _ in
            self?.frame(link)
            return kCVReturnSuccess
        }
        lock.withLock { displayLink = link }
        Log.info(String(format: "Display link ready, %.0f Hz", Self.rate(link)), "scroll")
    }

    private static func rate(_ link: CVDisplayLink) -> Double {
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        return period.timeValue > 0 ? Double(period.timeScale) / Double(period.timeValue) : 0
    }

    private func frame(_ link: CVDisplayLink) {
        let now = CACurrentMediaTime()
        let (result, event) = lock.withLock { () -> ((delta: (y: Double, x: Double)?, finished: Bool), CGEvent?) in
            stats.tick(now)
            let result = engine.frame(transition: transition)
            return (result, result.delta != nil ? template?.copy() : nil)
        }
        if let delta = result.delta, let event {
            // Only the point distance and "continuous", as Mos: writing the line or fixed-point
            // fields afterwards makes macOS recompute (zero) the point distance.
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta.y)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta.x)
            event.setIntegerValueField(.eventSourceUserData, value: ActionRunner.eventMarker)
            event.location = CGEvent(source: nil)?.location ?? event.location
            event.post(tap: .cgSessionEventTap)
            lock.withLock { stats.posted += 1 }
        }
        if result.finished {
            CVDisplayLinkStop(link)
            let summary = lock.withLock { () -> String in
                let text = stats.summary
                stats = FrameStats()
                template = nil
                return text
            }
            Log.debug("Scroll settled: \(summary)", "scroll")
        }
    }

    // MARK: - Event fields

    /// Mos: point delta, else fixed-point, else lines.
    private static func usable(_ event: CGEvent, axis: Int) -> Double {
        let point = event.getDoubleValueField(axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2)
        if point != 0 { return point }
        let fixed = event.getDoubleValueField(axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2)
        if fixed != 0 { return fixed }
        return Double(event.getIntegerValueField(axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2))
    }

    private static func fields(_ axis: Int) -> [CGEventField] {
        axis == 1
            ? [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1]
            : [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2]
    }

    private static func negate(_ event: CGEvent, axis: Int) {
        let fields = fields(axis)
        // Integer and double views of the same fields: read all first, then write (line first, as
        // writing it recomputes the others).
        let line = event.getIntegerValueField(fields[0])
        let point = event.getDoubleValueField(fields[1])
        let fixed = event.getDoubleValueField(fields[2])
        event.setIntegerValueField(fields[0], value: -line)
        event.setDoubleValueField(fields[2], value: -fixed)
        event.setDoubleValueField(fields[1], value: -point)
    }

    private static func clear(_ event: CGEvent, axis: Int) {
        let fields = fields(axis)
        event.setIntegerValueField(fields[0], value: 0)
        event.setDoubleValueField(fields[2], value: 0)
        event.setDoubleValueField(fields[1], value: 0)
    }
}
