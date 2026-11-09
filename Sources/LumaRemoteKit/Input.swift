import Foundation
import LumaRemoteCore

/// The One Euro filter (Casiez, Roussel and Vogel, CHI 2012): heavy smoothing while the pointer creeps,
/// little lag once it moves fast.
struct OneEuroFilter {
    var minimumCutoff: Double
    var beta: Double
    var derivativeCutoff = 1.0
    private var previous: Double?
    private var previousDerivative = 0.0

    init(minimumCutoff: Double = 1.0, beta: Double = 0.007) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
    }

    mutating func filter(_ value: Double, interval: Double) -> Double {
        guard let previous, interval > 0 else {
            self.previous = value
            return value
        }
        let derivative = (value - previous) / interval
        previousDerivative += Self.alpha(cutoff: derivativeCutoff, interval: interval) * (derivative - previousDerivative)
        let cutoff = minimumCutoff + beta * abs(previousDerivative)
        let filtered = previous + Self.alpha(cutoff: cutoff, interval: interval) * (value - previous)
        self.previous = filtered
        return filtered
    }

    mutating func reset() {
        previous = nil
        previousDerivative = 0
    }

    private static func alpha(cutoff: Double, interval: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / interval)
    }
}

/// Air-mouse geometry and gain. Turning about gravity moves the pointer across; tilting about the
/// horizontal axis across the phone moves it up and down, however the phone is rolled.
enum AirMouseMath {
    /// TV pixels per radian at an ordinary pointing speed.
    static let gain = 2750.0
    /// Rotation below about this rate counts as hand tremor.
    static let deadZone = 0.01

    struct Vector {
        var x, y, z: Double

        static func dot(_ a: Vector, _ b: Vector) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

        var length: Double { Vector.dot(self, self).squareRoot() }

        func scaled(_ factor: Double) -> Vector { Vector(x: x * factor, y: y * factor, z: z * factor) }

        func minus(_ other: Vector) -> Vector { Vector(x: x - other.x, y: y - other.y, z: z - other.z) }
    }

    /// Pointer rates in radians a second, right and down positive, from the device-frame rotation rate
    /// and gravity.
    static func pointerRates(rotation: Vector, gravity: Vector) -> (x: Double, y: Double) {
        let down = gravity.length > 0.1 ? gravity.scaled(1 / gravity.length) : Vector(x: 0, y: 0, z: -1)
        // Turning right is clockwise seen from above: positive about the downward axis.
        let yaw = Vector.dot(rotation, down)
        // The phone's x axis laid flat; tilting the top up is positive about it and moves the pointer up.
        let across = Vector(x: 1, y: 0, z: 0)
        let flat = across.minus(down.scaled(Vector.dot(across, down)))
        let pitch = flat.length > 0.1 ? Vector.dot(rotation, flat.scaled(1 / flat.length)) : rotation.x
        return (soften(yaw), -soften(pitch))
    }

    /// A soft dead zone: half strength at the threshold, untouched well above it.
    static func soften(_ rate: Double) -> Double {
        let squared = rate * rate
        return rate * squared / (squared + deadZone * deadZone)
    }

    /// Slower turns move less per radian, for precision; faster ones more.
    static func acceleration(_ speed: Double) -> Double {
        min(1.6, max(0.45, 0.45 + 0.35 * speed))
    }
}

/// Two-finger scroll momentum, computed on the phone: the release velocity decays like a UIKit scroll view's.
struct ScrollMomentum {
    /// Points a second.
    var velocityX: Double
    var velocityY: Double
    /// UIScrollView's normal deceleration, 0.998 a millisecond.
    static let decayPerSecond = pow(0.998, 1000.0)
    static let stopSpeed = 20.0

    /// The movement over `interval`, or nil once it has stopped.
    mutating func step(interval: Double) -> (dx: Double, dy: Double)? {
        guard (velocityX * velocityX + velocityY * velocityY).squareRoot() > Self.stopSpeed else { return nil }
        let decay = pow(Self.decayPerSecond, interval)
        // The distance travelled while the speed falls from v to v·decay.
        let factor = (decay - 1) / log(Self.decayPerSecond)
        let movement = (velocityX * factor, velocityY * factor)
        velocityX *= decay
        velocityY *= decay
        return movement
    }
}

/// The messages that turn the text the TV has into what the phone's field now holds: backspaces back to
/// their common start, then the rest as text.
enum TextDiff {
    static func messages(from old: String, to new: String) -> [ClientMessage] {
        let common = zip(old, new).prefix { $0 == $1 }.count
        var messages: [ClientMessage] = []
        var deletions = old.count - common
        while deletions > 0 {
            let count = min(deletions, 256)
            messages.append(.edit(.backspace(count)))
            deletions -= count
        }
        return messages + ClientMessage.textMessages(for: String(new.dropFirst(common)))
    }
}

/// A key under a finger. A quick release taps; holding past the threshold sends `down` for keys that
/// repeat (300 ms) or `hold` for the rest (500 ms), and letting go of a held repeating key sends `up`.
/// Home only ever taps.
struct KeyPress {
    let key: RemoteKey
    private(set) var held = false

    init(_ key: RemoteKey) {
        self.key = key
    }

    /// How long until the press counts as held; nil when it never does.
    var threshold: Duration? {
        if key.isTapOnly { return nil }
        return key.isHoldable ? .milliseconds(300) : .milliseconds(500)
    }

    /// The threshold passed with the finger still down.
    mutating func thresholdPassed() -> ClientMessage? {
        guard !held, threshold != nil else { return nil }
        held = true
        return .key(key, key.isHoldable ? .down : .hold)
    }

    /// The finger lifted.
    func released() -> ClientMessage? {
        guard held else { return .key(key, .tap) }
        return key.isHoldable ? .key(key, .up) : nil
    }

    /// The finger slid away: no tap, but a repeating key that went down must come up.
    func cancelled() -> ClientMessage? {
        held && key.isHoldable ? .key(key, .up) : nil
    }
}

/// Swipes on the D-pad: every 44 points along the leading axis is one arrow.
struct SwipeTracker {
    static let step = 44.0
    /// Travel before a touch counts as a swipe rather than a press.
    static let slop = 12.0

    private var anchorX: Double
    private var anchorY: Double

    init(x: Double, y: Double) {
        anchorX = x
        anchorY = y
    }

    /// The arrows passed since the last call. Each step re-centres the other axis, so drift across the
    /// swipe never adds up to a turn.
    mutating func move(x: Double, y: Double) -> [RemoteKey] {
        var keys: [RemoteKey] = []
        while true {
            let dx = x - anchorX
            let dy = y - anchorY
            if abs(dx) >= abs(dy), abs(dx) >= Self.step {
                keys.append(dx > 0 ? .right : .left)
                anchorX += dx > 0 ? Self.step : -Self.step
                anchorY = y
            } else if abs(dy) > abs(dx), abs(dy) >= Self.step {
                keys.append(dy > 0 ? .down : .up)
                anchorY += dy > 0 ? Self.step : -Self.step
                anchorX = x
            } else {
                return keys
            }
        }
    }
}

/// Fingers on the touchpad, turned into pointer actions. Positions are in points, times in seconds,
/// and motion out in TV pixels.
struct TrackpadTracker {
    enum Output: Equatable {
        case move(dx: Double, dy: Double)
        /// Positive scrolls right and down, as the pointer report counts it.
        case scroll(dx: Double, dy: Double)
        case scrolling(Bool)
        case click
        case press
        case release
        case back
        /// Two fingers left the pad still moving: scroll on at this many pixels a second, then stop.
        case fling(dx: Double, dy: Double)
    }

    static let tapTravel = 10.0
    static let tapTime = 0.25
    /// A touch this soon after a tap drags once it moves.
    static let dragWindow = 0.3
    static let scrollGain = 2.0
    /// Below this release speed, in pixels a second, scrolling just stops.
    static let flingSpeed = 150.0
    /// Fingers that rested this long before lifting were no longer moving, whatever their last speed.
    static let restBeforeLift = 0.1

    /// The setting that scales motion, 0.5–2.
    var speed = 1.0

    private enum Phase {
        case idle
        case one
        /// A touch right after a tap: a drag once it moves, another click if it lifts.
        case dragReady
        case dragging
        case two
    }

    private var phase = Phase.idle
    private var startTime = 0.0
    private var lastX = 0.0
    private var lastY = 0.0
    private var lastTime = 0.0
    private var touches = 0
    /// Fingers on the pad at the last update.
    private var fingers = 0
    private var travel = 0.0
    private var lastTap: Double?
    private var velocityX = 0.0
    private var velocityY = 0.0

    /// Pixels per point: slow strokes are precise, quick ones cross the screen.
    static func gain(speed pointsPerSecond: Double) -> Double {
        min(4, max(1.2, 1.2 + pointsPerSecond / 500))
    }

    /// The fingers changed: `count` on the pad now, their centre at `x`, `y`.
    mutating func update(count: Int, x: Double, y: Double, time: Double) -> [Output] {
        switch phase {
        case .idle:
            guard count > 0 else { return [] }
            begin(count: count, x: x, y: y, time: time)
            if count >= 2 {
                phase = .two
                return [.scrolling(true)]
            }
            if let lastTap, time - lastTap <= Self.dragWindow {
                phase = .dragReady
            } else {
                phase = .one
            }
            return []
        case .one, .dragReady, .dragging:
            if count == 0 { return lift(time: time) }
            if count >= 2, phase != .dragging {
                phase = .two
                touches = count
                fingers = count
                anchor(x: x, y: y, time: time)
                return [.scrolling(true)]
            }
            if count != fingers {
                // The centre jumps when a finger joins a drag: carry on from the new one.
                fingers = count
                anchor(x: x, y: y, time: time)
                return []
            }
            return moveOne(x: x, y: y, time: time)
        case .two:
            touches = max(touches, count)
            if count == 0 { return lift(time: time) }
            // A finger joining or leaving moves the centre without scrolling, and one finger left alone
            // waits for the other.
            if count != fingers || count == 1 {
                fingers = count
                anchor(x: x, y: y, time: time)
                return []
            }
            return scrollTwo(x: x, y: y, time: time)
        }
    }

    private mutating func begin(count: Int, x: Double, y: Double, time: Double) {
        startTime = time
        touches = count
        fingers = count
        travel = 0
        velocityX = 0
        velocityY = 0
        anchor(x: x, y: y, time: time)
    }

    private mutating func anchor(x: Double, y: Double, time: Double) {
        lastX = x
        lastY = y
        lastTime = time
    }

    private mutating func moveOne(x: Double, y: Double, time: Double) -> [Output] {
        let dx = x - lastX
        let dy = y - lastY
        let interval = max(time - lastTime, 0.001)
        anchor(x: x, y: y, time: time)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return [] }
        travel += distance
        var outputs: [Output] = []
        if phase == .dragReady, travel > Self.tapTravel {
            phase = .dragging
            lastTap = nil
            outputs.append(.press)
        }
        let gain = Self.gain(speed: distance / interval) * speed
        outputs.append(.move(dx: dx * gain, dy: dy * gain))
        return outputs
    }

    private mutating func scrollTwo(x: Double, y: Double, time: Double) -> [Output] {
        let dx = x - lastX
        let dy = y - lastY
        let interval = max(time - lastTime, 0.001)
        anchor(x: x, y: y, time: time)
        travel += (dx * dx + dy * dy).squareRoot()
        // Content follows the fingers, so scrolling runs against them.
        let scrollX = -dx * Self.scrollGain * speed
        let scrollY = -dy * Self.scrollGain * speed
        // Smoothed over the last few samples, so the release speed is not one jittery sample.
        velocityX = velocityX * 0.5 + scrollX / interval * 0.5
        velocityY = velocityY * 0.5 + scrollY / interval * 0.5
        return scrollX == 0 && scrollY == 0 ? [] : [.scroll(dx: scrollX, dy: scrollY)]
    }

    private mutating func lift(time: Double) -> [Output] {
        let quick = travel <= Self.tapTravel && time - startTime <= Self.tapTime
        let ended = phase
        phase = .idle
        switch ended {
        case .idle:
            return []
        case .one:
            guard quick else { return [] }
            lastTap = time
            return [.click]
        case .dragReady:
            lastTap = nil
            return travel <= Self.tapTravel ? [.click] : []
        case .dragging:
            return [.release]
        case .two:
            lastTap = nil
            if quick, touches >= 2 { return [.scrolling(false), .back] }
            if time - lastTime <= Self.restBeforeLift,
               (velocityX * velocityX + velocityY * velocityY).squareRoot() >= Self.flingSpeed {
                return [.fling(dx: velocityX, dy: velocityY)]
            }
            return [.scrolling(false)]
        }
    }
}

/// The median, 95th percentile and worst of a set of round trips, by nearest rank.
public struct LatencySummary: Sendable, Equatable {
    public var count: Int
    public var median: Duration
    public var p95: Duration
    public var worst: Duration

    public init?(_ samples: [Duration]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func rank(_ percentile: Double) -> Duration {
            sorted[max(0, Int((percentile * Double(sorted.count)).rounded(.up)) - 1)]
        }
        count = sorted.count
        median = rank(0.5)
        p95 = rank(0.95)
        worst = sorted[sorted.count - 1]
    }
}
