import Foundation

/// A held gesture button: mouse movement (raw XY from the mouse, the pointer stays still) adds
/// up, and past the threshold it becomes one swipe per press. Sideways wins unless the movement
/// is clearly vertical (`verticalBias` times more), since pressing the button itself jolts the mouse
/// up or down a little and a sideways swipe often drifts. Released without a swipe = a click.
///
/// The first report after the press is skipped: it carries the movement made before the press
/// (the pointer was still travelling), often hundreds of units the other way or downwards, and it
/// alone used to decide half the swipes (log of 2026-10-20: 11 of 22 presses went wrong).
struct GestureTracker {
    var threshold: Int
    var verticalBias = 1.5

    private(set) var dx = 0
    private(set) var dy = 0
    private(set) var swiped = false
    private var skippedFirst = false

    init(threshold: Int) {
        self.threshold = threshold
    }

    mutating func begin() {
        dx = 0
        dy = 0
        swiped = false
        skippedFirst = false
    }

    /// `dy` grows downwards, as the mouse reports it.
    mutating func move(dx: Int, dy: Int) -> SwipeDirection? {
        guard !swiped else { return nil }
        guard skippedFirst else {
            skippedFirst = true
            return nil
        }
        self.dx += dx
        self.dy += dy
        guard max(abs(self.dx), abs(self.dy)) >= threshold else { return nil }
        swiped = true
        if Double(abs(self.dy)) >= Double(abs(self.dx)) * verticalBias {
            return self.dy > 0 ? .down : .up
        }
        return self.dx > 0 ? .right : .left
    }

    /// True when the press was a click (no swipe).
    mutating func end() -> Bool {
        defer { begin() }
        return !swiped
    }
}

/// One press of the gesture button, kept for the log: every raw XY report with its time since the
/// press, the moment the swipe was decided, the movement after it (the tracker stops adding then)
/// and the pointer at press and release. Logged as one short line at release; the reports
/// themselves only when the swipe looks wrong (`looksWrong`) or the log is verbose, so a wrong
/// desktop or an unexpected Mission Control can be matched with what the hand actually did.
struct GestureTrace {
    struct Sample {
        var ms: Int
        var dx: Int
        var dy: Int
    }

    var samples: [Sample] = []
    /// `sample` is the index of the report that crossed the threshold.
    var decision: (sample: Int, direction: SwipeDirection, dx: Int, dy: Int)?
    var pointerDown: CGPoint?
    var pointerUp: CGPoint?

    var totalX: Int { samples.reduce(0) { $0 + $1.dx } }
    var totalY: Int { samples.reduce(0) { $0 + $1.dy } }

    mutating func add(ms: Int, dx: Int, dy: Int) {
        samples.append(Sample(ms: ms, dx: dx, dy: dy))
    }

    /// The swipe disagrees with the whole press (all reports but the skipped first one, judged as
    /// `GestureTracker` does): the hand went one way, the decision another.
    func looksWrong(verticalBias: Double = 1.5) -> Bool {
        guard let decision, let first = samples.first else { return false }
        let dx = totalX - first.dx, dy = totalY - first.dy
        let whole: SwipeDirection = Double(abs(dy)) >= Double(abs(dx)) * verticalBias
            ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left)
        return whole != decision.direction
    }

    /// `held` in ms; `result` is what ran ("click → Mission Control", "swipe right → …").
    func summary(held: Int, threshold: Int, result: String, withMoves: Bool = true) -> String {
        var parts = ["held \(held) ms", "threshold \(threshold)", "\(samples.count) moves",
                     "total dx \(totalX) dy \(totalY)"]
        if let first = samples.first {
            parts.append("first skipped (dx \(first.dx) dy \(first.dy))")
        }
        if let decision {
            let after = samples[(decision.sample + 1)...]
            parts.append("decided \(decision.direction.rawValue) at +\(samples[decision.sample].ms) ms (dx \(decision.dx) dy \(decision.dy))")
            parts.append("after it dx \(after.reduce(0) { $0 + $1.dx }) dy \(after.reduce(0) { $0 + $1.dy })")
        }
        if let down = pointerDown, let up = pointerUp {
            parts.append("pointer (\(Int(down.x)),\(Int(down.y))) → (\(Int(up.x)),\(Int(up.y)))")
        }
        let moves = !withMoves ? "" : samples.map { "+\($0.ms):\($0.dx),\($0.dy)" }.joined(separator: " ")
        let tail = withMoves && !moves.isEmpty ? " | moves \(moves)" : ""
        return "\(result) | " + parts.joined(separator: ", ") + tail
    }
}

/// Mos's smooth scrolling, frame by frame: each wheel notch adds a distance to a buffer, every
/// display frame moves a fixed share of what is left (`transition`), and a short low-pass filter
/// softens the start. A notch in the other direction drops what was left.
struct ScrollEngine {
    struct Axis {
        var buffer = 0.0
        var current = 0.0
        var lastInput = 0.0
        /// Filter state (Mos ScrollFilter): the output lags one frame and follows the new value by 23 %.
        var filtered = 0.0

        mutating func add(_ value: Double) {
            if value * lastInput > 0 {
                buffer += value
            } else {
                buffer = value
                current = 0
            }
            lastInput = value
        }

        mutating func frame(transition: Double) -> Double {
            let step = (buffer - current) * transition
            current += step
            let output = filtered
            filtered = output + 0.23 * (step - output)
            return output
        }

        var residual: Double { buffer - current }
    }

    var y = Axis()
    var x = Axis()
    var deadZone = 1.0

    /// Mos: duration 0…5 → the share moved per frame (1 − √(duration / 5.2)).
    static func transition(duration: Double) -> Double {
        let value = 1 - (min(max(duration, 0), 5) / 5.2).squareRoot()
        return (value * 1000).rounded() / 1000
    }

    /// A notch shorter than `step` counts as `step` (keeps its sign).
    static func normalized(_ value: Double, step: Double) -> Double {
        guard value != 0, abs(value) < step else { return value }
        return value > 0 ? step : -step
    }

    mutating func add(y dy: Double, x dx: Double) {
        if dy != 0 { y.add(dy) }
        if dx != 0 { x.add(dx) }
    }

    /// The distance to post this frame (nil = too small to post) and whether scrolling has settled.
    mutating func frame(transition: Double) -> (delta: (y: Double, x: Double)?, finished: Bool) {
        let outY = y.frame(transition: transition)
        let outX = x.frame(transition: transition)
        let output = max(abs(outY), abs(outX))
        let residual = max(abs(y.residual), abs(x.residual))
        let finished = residual <= deadZone && output <= deadZone
        if finished { reset() }
        return (output > deadZone ? (outY, outX) : nil, finished)
    }

    mutating func reset() {
        y = Axis()
        x = Axis()
    }
}
