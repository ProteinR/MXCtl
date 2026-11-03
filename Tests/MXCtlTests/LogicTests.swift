import XCTest
@testable import MXCtl

final class LogicTests: XCTestCase {
    // MARK: HID++

    func testRequestLayout() {
        let report = HIDPP.request(featureIndex: 0x09, function: 3, params: [0x01, 0x0A, 0x03])
        XCTAssertEqual(report.count, 20)
        XCTAssertEqual(Array(report.prefix(7)), [0x11, 0xFF, 0x09, 0x3B, 0x01, 0x0A, 0x03])
    }

    func testParseAnswerAndError() {
        var answer = [UInt8](repeating: 0, count: 20)
        answer[0...5] = [0x11, 0xFF, 0x00, 0x1B, 0x04, 0x05]
        let message = HIDPP.parse(answer)
        XCTAssertEqual(message?.function, 1)
        XCTAssertEqual(message?.softwareID, HIDPP.softwareID)
        XCTAssertEqual(message?.params.prefix(2), [0x04, 0x05])
        XCTAssertEqual(message?.isError, false)

        let error = HIDPP.parse([0x11, 0xFF, 0xFF, 0x09, 0x3B, 0x05, 0, 0])
        XCTAssertEqual(error?.isError, true)
        XCTAssertEqual(error?.params.first, 0x09)
        XCTAssertEqual(error?.function, 3)
        XCTAssertEqual(error?.errorCode, 0x05)

        XCTAssertNil(HIDPP.parse([0x10, 0xFF, 0x00, 0x1B]))
    }

    func testCidInfo() {
        // cid 00C3, task 00A9, flags 0x30 (reprogrammable, divertable), pos, group, gmask, flags2 0x01 (raw XY)
        let control = ReprogControls.control(from: [0x00, 0xC3, 0x00, 0xA9, 0x30, 0, 3, 0x1F, 0x01])
        XCTAssertEqual(control.cid, 0x00C3)
        XCTAssertTrue(control.isDivertable)
        XCTAssertTrue(control.hasRawXY)
        XCTAssertFalse(ReprogControls.control(from: [0x00, 0x50, 0, 0x38, 0x01, 0, 0, 0, 0]).isDivertable)
    }

    func testReportingFlags() {
        XCTAssertEqual(ReprogControls.reportingParams(cid: 0x010A, divert: true, rawXY: false), [0x01, 0x0A, 0x03, 0, 0])
        XCTAssertEqual(ReprogControls.reportingParams(cid: 0x00C3, divert: true, rawXY: true), [0x00, 0xC3, 0x33, 0, 0])
        XCTAssertEqual(ReprogControls.reportingParams(cid: 0x00C3, divert: false, rawXY: false), [0x00, 0xC3, 0x22, 0, 0])
    }

    func testDivertedEvents() {
        XCTAssertEqual(ReprogControls.pressedControls(from: [0x00, 0xC3, 0x01, 0x0A, 0, 0, 0, 0]), [0x00C3, 0x010A])
        XCTAssertEqual(ReprogControls.pressedControls(from: [0, 0, 0, 0, 0, 0, 0, 0]), [])
        let move = ReprogControls.rawXY(from: [0xFF, 0xF6, 0x00, 0x05])
        XCTAssertEqual(move.dx, -10)
        XCTAssertEqual(move.dy, 5)
    }

    func testSmartShift() {
        XCTAssertEqual(SmartShift.state(from: [2, 18, 30]), SmartShift.State(mode: .ratchet, threshold: 18))
        XCTAssertEqual(SmartShift.params(SmartShift.State(mode: .keep, threshold: 40)), [0, 40])
        XCTAssertEqual(SmartShift.readFunction(enhanced: true), 1)
        XCTAssertEqual(SmartShift.writeFunction(enhanced: false), 1)
    }

    func testBacklightConfig() {
        // What MX Keys Mini answered on 2026-10-19 (Options+: automatic, level 4/8, 30 s, 30 s, 5 min).
        let raw: [UInt8] = [0x01, 0x0D, 0x3D, 0x01, 0x00, 0x04, 0x06, 0x00, 0x06, 0x00, 0x3C, 0x00, 0, 0, 0, 0]
        let config = BacklightConfig(params: raw)
        XCTAssertEqual(config?.enabled, true)
        XCTAssertEqual(config?.isAutomatic, true)
        XCTAssertEqual(config?.level, 4)
        XCTAssertEqual(config?.handsOut, 6)
        XCTAssertEqual(config?.powered, 60)
        var off = config!
        off.enabled = false
        XCTAssertEqual(off.writeParams, [0x00, 0x0D, 0xFF, 0x00, 0x06, 0x00, 0x06, 0x00, 0x3C, 0x00])
        XCTAssertNil(BacklightConfig(params: [1, 2, 3]))
    }

    // MARK: Gestures

    func testGestureClickAndSwipe() {
        var gesture = GestureTracker(threshold: 50)
        gesture.begin()
        XCTAssertNil(gesture.move(dx: 0, dy: 0), "the first report is skipped")
        XCTAssertNil(gesture.move(dx: 10, dy: 3))
        XCTAssertTrue(gesture.end(), "small movement is still a click")

        gesture.begin()
        XCTAssertNil(gesture.move(dx: 0, dy: 0))
        XCTAssertNil(gesture.move(dx: -30, dy: 5))
        XCTAssertEqual(gesture.move(dx: -30, dy: 5), .left)
        XCTAssertNil(gesture.move(dx: 0, dy: -200), "one swipe per press")
        XCTAssertFalse(gesture.end())

        gesture.begin()
        XCTAssertNil(gesture.move(dx: 0, dy: 0))
        XCTAssertEqual(gesture.move(dx: 5, dy: -70), .up)
        gesture.begin()
        XCTAssertNil(gesture.move(dx: 0, dy: 0))
        XCTAssertEqual(gesture.move(dx: 5, dy: 70), .down)
    }

    func testSidewaysWinsOverPressJolt() {
        var gesture = GestureTracker(threshold: 60)
        gesture.begin()
        XCTAssertNil(gesture.move(dx: 0, dy: 0))
        // The press pushes the mouse up a bit, then the hand moves right with some drift.
        XCTAssertNil(gesture.move(dx: 0, dy: -20))
        XCTAssertEqual(gesture.move(dx: 45, dy: -40), .right)
    }

    /// Presses from the log of 2026-10-20: the first report is movement from before the press.
    func testFirstReportAfterPressIsIgnored() {
        func decide(_ moves: [(Int, Int)]) -> SwipeDirection? {
            var gesture = GestureTracker(threshold: 100)
            gesture.begin()
            for (dx, dy) in moves {
                if let direction = gesture.move(dx: dx, dy: dy) { return direction }
            }
            return nil
        }
        // Was "right" (the desktop on the wrong side): the hand went left.
        XCTAssertEqual(decide([(789, 43), (-23, -4), (-20, -2), (-15, 0), (-27, -1), (-31, -1), (-30, 0)]), .left)
        // Was "down" (App Exposé): the hand went right.
        XCTAssertEqual(decide([(94, 144), (1, 0), (6, 0), (8, 0), (13, 0), (17, 0), (18, 0), (22, -1), (21, -2), (30, -2)]), .right)
        // Was "left" from the stale report alone: the press was a click.
        XCTAssertNil(decide([(-226, 0), (1, 0), (0, 1)]))
    }

    func testGestureTraceSummary() {
        var trace = GestureTrace()
        trace.add(ms: 5, dx: 0, dy: -20)
        trace.add(ms: 12, dx: 45, dy: -40)
        trace.decision = (1, .right, 45, -60)
        trace.add(ms: 30, dx: -80, dy: 3)
        let line = trace.summary(held: 300, threshold: 60, result: "swipe right → Рабочий стол справа")
        XCTAssertTrue(line.hasPrefix("swipe right → Рабочий стол справа | held 300 ms"))
        XCTAssertTrue(line.contains("total dx -35 dy -57, first skipped (dx 0 dy -20)"))
        XCTAssertTrue(line.contains("decided right at +12 ms (dx 45 dy -60), after it dx -80 dy 3"))
        XCTAssertTrue(line.hasSuffix("moves +5:0,-20 +12:45,-40 +30:-80,3"))
    }

    func testGestureTraceLooksWrong() {
        var trace = GestureTrace()
        trace.add(ms: 8, dx: 789, dy: 43)   // skipped: movement from before the press
        trace.add(ms: 15, dx: -60, dy: 0)
        trace.add(ms: 22, dx: -60, dy: 0)
        trace.decision = (2, .left, -120, 0)
        XCTAssertFalse(trace.looksWrong())
        trace.add(ms: 30, dx: 400, dy: 0)    // the hand went right after all
        XCTAssertTrue(trace.looksWrong())
        XCTAssertFalse(trace.summary(held: 100, threshold: 100, result: "x", withMoves: false).contains("moves +"))
    }

    // MARK: Smooth scrolling

    func testTransitionMatchesMos() {
        XCTAssertEqual(ScrollEngine.transition(duration: 2.75), 0.273, accuracy: 0.0005)
        XCTAssertEqual(ScrollEngine.transition(duration: 4.35), 0.085, accuracy: 0.0005)
        XCTAssertEqual(ScrollEngine.normalized(3, step: 50), 50)
        XCTAssertEqual(ScrollEngine.normalized(-3, step: 50), -50)
        XCTAssertEqual(ScrollEngine.normalized(80, step: 50), 80)
    }

    func testEngineDeliversTheWholeNotch() {
        var engine = ScrollEngine()
        engine.add(y: 53.5, x: 0)
        var total = 0.0
        var frames = 0
        while frames < 500 {
            frames += 1
            let result = engine.frame(transition: 0.273)
            total += result.delta?.y ?? 0
            if result.finished { break }
        }
        XCTAssertLessThan(frames, 100)
        XCTAssertEqual(total, 53.5, accuracy: 6, "almost all of it, minus the dead zone tail")
    }

    func testOppositeNotchDropsTheRest() {
        var engine = ScrollEngine()
        engine.add(y: 50, x: 0)
        _ = engine.frame(transition: 0.273)
        engine.add(y: -50, x: 0)
        XCTAssertEqual(engine.y.residual, -50, accuracy: 0.001)
    }

    // MARK: Battery

    func testBatteryAlertsOncePerDischarge() {
        let rule = BatteryAlertRule(warning: 15, critical: 5)
        var shown = BatteryAlertRule.Level.none
        func check(_ percent: Int, charging: Bool = false) -> BatteryAlertRule.Level? {
            let result = rule.check(percent: percent, charging: charging, alreadyShown: shown)
            shown = result.remember
            return result.show
        }
        XCTAssertNil(check(40))
        XCTAssertEqual(check(15), .warning)
        XCTAssertNil(check(12), "warning only once")
        XCTAssertEqual(check(5), .critical)
        XCTAssertNil(check(3), "critical only once")
        XCTAssertNil(check(3, charging: true), "nothing while charging")
        XCTAssertNil(check(60))
        XCTAssertEqual(check(14), .warning, "a new discharge warns again")
        shown = .none
        XCTAssertEqual(check(4), .critical, "straight to critical when found that low")
    }

    func testBatteryBarsCarryAndCharging() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400))
        func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }
        let readings = [(at(1.2), 60, false), (at(3.5), 55, false), (at(4.1), 55, true), (at(4.8), 70, true), (at(5.2), 70, false)]
            .map { (time: $0.0, percent: $0.1, charging: $0.2) }
        let bars = BatteryBar.bars(readings: readings, from: at(0), to: at(7), slot: 3600, calendar: calendar)
        XCTAssertEqual(bars.first?.start, at(1), "nothing before the first reading")
        XCTAssertEqual(bars.map(\.percent), [60, 60, 55, 70, 70, 70])
        XCTAssertEqual(bars.map(\.charging), [false, false, false, true, true, false])
        XCTAssertEqual(bars[3].state, .charging)
        XCTAssertEqual(BatteryBar(start: at(0), percent: 15, charging: false).state, .low)
    }

    func testBatterySegments() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }
        let readings = [(at(-5), 40, false), (at(1), 35, false), (at(2), 35, true), (at(3), 60, true), (at(4), 18, false)]
            .map { (time: $0.0, percent: $0.1, charging: $0.2) }
        let segments = BatterySegment.segments(readings: readings, from: at(0), to: at(6))
        XCTAssertEqual(segments.map(\.percent), [40, 35, 35, 60, 18])
        XCTAssertEqual(segments.first?.start, at(0), "starts at the period with the earlier charge")
        XCTAssertEqual(segments.map(\.state), [.normal, .normal, .charging, .charging, .low])
        XCTAssertEqual(segments.last?.end, at(6))
        XCTAssertEqual(segments[0].next, 35)
        XCTAssertNil(segments.last?.next)
    }

    // MARK: Config

    func testFullCharge() {
        func reading(_ percent: Int, _ charging: Bool) -> JournalEvent {
            JournalEvent(time: Date(), kind: .battery, device: "M", percent: percent, charging: charging)
        }
        XCTAssertTrue(EventJournal.isFullCharge(reading(100, true), after: nil))
        XCTAssertTrue(EventJournal.isFullCharge(reading(96, false), after: reading(96, true)))
        XCTAssertFalse(EventJournal.isFullCharge(reading(96, false), after: reading(97, false)))
        XCTAssertFalse(EventJournal.isFullCharge(reading(90, false), after: reading(90, true)))
        // Still full: the same charge, not a new one.
        XCTAssertFalse(EventJournal.isFullCharge(reading(100, false), after: reading(100, true)))
        XCTAssertFalse(EventJournal.isFullCharge(reading(100, false), after: reading(100, false)))
        XCTAssertFalse(EventJournal.isFullCharge(reading(98, false), after: reading(100, true)))
        XCTAssertTrue(EventJournal.isFullCharge(reading(100, true), after: reading(95, true)))
    }

    func testConfigDefaultsAndRoundTrip() throws {
        let empty = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.binding(KnownControl.screenCapture).click, .keystroke(.screenshotArea))
        XCTAssertEqual(empty.binding(KnownControl.micMute).click, .system(.micMute))
        XCTAssertTrue(empty.binding(KnownControl.gestureButton).usesSwipes)
        XCTAssertEqual(empty.binding(KnownControl.emoji).click, .native)
        XCTAssertNil(empty.smartShift.threshold)

        var config = Config()
        config.bindings[Config.key(KnownControl.forward)] = ButtonBinding(click: .openURL("shortcuts://run-shortcut?name=X"))
        config.scroll.step = 30
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), config)
    }
}
