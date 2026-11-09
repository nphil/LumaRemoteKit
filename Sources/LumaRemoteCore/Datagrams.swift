#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The pointer channel's UDP datagrams: a 12-byte header in clear, authenticated as associated data,
/// then the sealed body.
public enum Datagram {
    public enum Kind: UInt8, Sendable {
        /// Phone to TV.
        case pointer = 1
        /// Phone to TV.
        case ping = 2
        /// TV to phone.
        case pong = 3
    }

    public enum Direction: UInt8, Sendable {
        case phoneToTV = 0
        case tvToPhone = 1
    }

    public struct Header: Sendable, Hashable {
        public var kind: Kind
        public var session: UInt32
        public var sequence: UInt32

        public init(kind: Kind, session: UInt32, sequence: UInt32) {
            self.kind = kind
            self.session = session
            self.sequence = sequence
        }

        public static let length = 12

        var bytes: Data {
            var bytes = Data([0x4C, 0x52, 1, kind.rawValue])
            bytes.appendLittleEndian(session)
            bytes.appendLittleEndian(sequence)
            return bytes
        }

        /// Nil for a wrong magic, version or kind.
        init?(_ bytes: Data) {
            guard bytes.count >= Self.length,
                  bytes[bytes.startIndex] == 0x4C, bytes[bytes.startIndex + 1] == 0x52, bytes[bytes.startIndex + 2] == 1,
                  let kind = Kind(rawValue: bytes[bytes.startIndex + 3])
            else { return nil }
            self.kind = kind
            session = bytes.littleEndian(UInt32.self, at: 4)
            sequence = bytes.littleEndian(UInt32.self, at: 8)
        }
    }

    public enum OpenError: Error, Equatable {
        case badHeader
        case authenticationFailed
    }

    /// `4C 52 D 00`, then the sequence as u64.
    static func nonce(_ direction: Direction, sequence: UInt32) -> Data {
        var nonce = Data([0x4C, 0x52, direction.rawValue, 0])
        nonce.appendLittleEndian(UInt64(sequence))
        return nonce
    }

    public static func seal(_ header: Header, body: Data, key: Data, direction: Direction) throws -> Data {
        let headerBytes = header.bytes
        let sealed = try ChaCha.seal(body, key: SymmetricKey(data: key), nonce: nonce(direction, sequence: header.sequence), associatedData: headerBytes)
        return headerBytes + sealed
    }

    public static func open(_ datagram: Data, key: Data, direction: Direction) throws -> (header: Header, body: Data) {
        guard let header = Header(datagram) else { throw OpenError.badHeader }
        let headerBytes = datagram.prefix(Header.length)
        do {
            let body = try ChaCha.open(datagram.dropFirst(Header.length), key: SymmetricKey(data: key), nonce: nonce(direction, sequence: header.sequence), associatedData: headerBytes)
            return (header, body)
        } catch {
            throw OpenError.authenticationFailed
        }
    }
}

/// A pointer datagram's 24-byte body: totals since the session began, so a lost datagram loses nothing.
public struct PointerReport: Sendable, Hashable {
    public struct Buttons: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let left = Buttons(rawValue: 1)
        public static let right = Buttons(rawValue: 2)
    }

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// Show the pointer and keep it shown.
        public static let engaged = Flags(rawValue: 1)
        /// Fingers are on the scroll surface.
        public static let scrolling = Flags(rawValue: 2)
    }

    public static let length = 24

    /// Pointer motion in 1/16 TV pixel, right and down positive, wrapping.
    public var x: Int32 = 0
    public var y: Int32 = 0
    /// Scrolling in 1/16 px; positive scrolls right and down (content moves left and up).
    public var scrollX: Int32 = 0
    public var scrollY: Int32 = 0
    public var held: Buttons = []
    /// Presses since the session began, wrapping.
    public var leftPresses: UInt8 = 0
    public var rightPresses: UInt8 = 0
    /// Centring requests, wrapping; the TV centres the pointer once for any change.
    public var centres: UInt8 = 0
    public var flags: Flags = []

    public init() {}

    public var bytes: Data {
        var bytes = Data(capacity: Self.length)
        bytes.appendLittleEndian(x)
        bytes.appendLittleEndian(y)
        bytes.appendLittleEndian(scrollX)
        bytes.appendLittleEndian(scrollY)
        bytes.append(contentsOf: [held.rawValue, leftPresses, rightPresses, centres, flags.rawValue, 0, 0, 0])
        return bytes
    }

    public init?(_ bytes: Data) {
        guard bytes.count == Self.length else { return nil }
        x = bytes.littleEndian(Int32.self, at: 0)
        y = bytes.littleEndian(Int32.self, at: 4)
        scrollX = bytes.littleEndian(Int32.self, at: 8)
        scrollY = bytes.littleEndian(Int32.self, at: 12)
        let tail = bytes.startIndex + 16
        held = Buttons(rawValue: bytes[tail])
        leftPresses = bytes[tail + 1]
        rightPresses = bytes[tail + 2]
        centres = bytes[tail + 3]
        flags = Flags(rawValue: bytes[tail + 4])
    }
}

/// A ping's body: an id and the phone's clock in microseconds. The pong echoes both and adds how long
/// the TV held the ping.
public struct PingBody: Sendable, Hashable {
    public var id: UInt32
    public var time: UInt64
    /// Only in a pong.
    public var hold: UInt32?

    public init(id: UInt32, time: UInt64, hold: UInt32? = nil) {
        self.id = id
        self.time = time
        self.hold = hold
    }

    public var bytes: Data {
        var bytes = Data()
        bytes.appendLittleEndian(id)
        bytes.appendLittleEndian(time)
        if let hold { bytes.appendLittleEndian(hold) }
        return bytes
    }

    /// 12 bytes for a ping, 16 for a pong.
    public init?(_ bytes: Data) {
        guard bytes.count == 12 || bytes.count == 16 else { return nil }
        id = bytes.littleEndian(UInt32.self, at: 0)
        time = bytes.littleEndian(UInt64.self, at: 4)
        hold = bytes.count == 16 ? bytes.littleEndian(UInt32.self, at: 12) : nil
    }
}

public enum PointerButton: Sendable, Hashable {
    case left, right
}

/// The phone's running totals. Motion arrives in TV pixels as doubles; the fraction below 1/16 px is
/// carried to the next sample rather than dropped.
public struct PointerAccumulator: Sendable {
    public private(set) var report = PointerReport()
    private var restX = 0.0
    private var restY = 0.0
    private var restScrollX = 0.0
    private var restScrollY = 0.0

    public init() {}

    public mutating func move(dx: Double, dy: Double) {
        report.x = report.x &+ Self.take(dx, rest: &restX)
        report.y = report.y &+ Self.take(dy, rest: &restY)
    }

    public mutating func scroll(dx: Double, dy: Double) {
        report.scrollX = report.scrollX &+ Self.take(dx, rest: &restScrollX)
        report.scrollY = report.scrollY &+ Self.take(dy, rest: &restScrollY)
    }

    /// The button goes down and stays down.
    public mutating func press(_ button: PointerButton) {
        count(button)
        report.held.insert(button == .left ? .left : .right)
    }

    public mutating func release(_ button: PointerButton) {
        report.held.remove(button == .left ? .left : .right)
    }

    /// A press and release in one step.
    public mutating func click(_ button: PointerButton) {
        count(button)
    }

    public mutating func centre() {
        report.centres = report.centres &+ 1
    }

    public mutating func set(_ flag: PointerReport.Flags, _ on: Bool) {
        if on { report.flags.insert(flag) } else { report.flags.remove(flag) }
    }

    private mutating func count(_ button: PointerButton) {
        switch button {
        case .left: report.leftPresses = report.leftPresses &+ 1
        case .right: report.rightPresses = report.rightPresses &+ 1
        }
    }

    /// Whole sixteenths of `pixels` plus the carried rest; the new rest stays below one sixteenth.
    private static func take(_ pixels: Double, rest: inout Double) -> Int32 {
        guard pixels.isFinite else { return 0 }
        let total = pixels * 16 + rest
        let whole = total.rounded(.towardZero)
        rest = total - whole
        return Int32(truncatingIfNeeded: Int64(max(-1e9, min(1e9, whole))))
    }
}

/// What the TV does with one accepted pointer datagram, in order.
public enum PointerEvent: Sendable, Hashable, CustomStringConvertible {
    /// The pointer shows (true) or is let go (false), following the `engaged` flag.
    case engaged(Bool)
    case centre
    /// In 1/16 px.
    case move(dx: Int32, dy: Int32)
    /// In 1/16 px.
    case scroll(dx: Int32, dy: Int32)
    case click(PointerButton)
    case press(PointerButton)
    case release(PointerButton)

    public var description: String {
        switch self {
        case .engaged(let on): "engaged \(on ? "on" : "off")"
        case .centre: "centre"
        case .move(let dx, let dy): "move \(dx) \(dy)"
        case .scroll(let dx, let dy): "scroll \(dx) \(dy)"
        case .click(let button): "click \(button == .left ? "left" : "right")"
        case .press(let button): "press \(button == .left ? "left" : "right")"
        case .release(let button): "release \(button == .left ? "left" : "right")"
        }
    }
}

/// The TV's side of the totals, as LumaTV's engine applies them: turns each accepted datagram into
/// events from the difference to the last accepted one (wrapping subtraction). Used by the fake TV and
/// to check the vectors.
public struct PointerApplier: Sendable {
    /// At most 4,096 px per datagram on each axis, in 1/16 px.
    public static let motionLimit: Int32 = 4096 * 16

    private var last: PointerReport

    /// `last` is the last accepted totals: zero when a session opens.
    public init(last: PointerReport = PointerReport()) {
        self.last = last
    }

    /// Newly engaged first, then one centre for any change of the count, motion, scroll, each button,
    /// and newly let go last.
    public mutating func apply(_ report: PointerReport) -> [PointerEvent] {
        var events: [PointerEvent] = []
        let engaged = report.flags.contains(.engaged)
        let wasEngaged = last.flags.contains(.engaged)
        if engaged && !wasEngaged { events.append(.engaged(true)) }
        if report.centres != last.centres { events.append(.centre) }
        let dx = report.x &- last.x
        let dy = report.y &- last.y
        if dx != 0 || dy != 0 { events.append(.move(dx: Self.clamp(dx), dy: Self.clamp(dy))) }
        let sx = report.scrollX &- last.scrollX
        let sy = report.scrollY &- last.scrollY
        if sx != 0 || sy != 0 { events.append(.scroll(dx: sx, dy: sy)) }
        events += Self.buttonEvents(.left, presses: report.leftPresses &- last.leftPresses,
                                    held: report.held.contains(.left), wasHeld: last.held.contains(.left))
        events += Self.buttonEvents(.right, presses: report.rightPresses &- last.rightPresses,
                                    held: report.held.contains(.right), wasHeld: last.held.contains(.right))
        if !engaged && wasEngaged { events.append(.engaged(false)) }
        last = report
        return events
    }

    /// k presses since the last datagram: k clicks with the button up, k − 1 clicks and a press with it
    /// held; no presses and the button newly up, a release.
    private static func buttonEvents(_ button: PointerButton, presses: UInt8, held: Bool, wasHeld: Bool) -> [PointerEvent] {
        guard presses > 0 else { return wasHeld && !held ? [.release(button)] : [] }
        let clicks = [PointerEvent](repeating: .click(button), count: Int(held ? presses - 1 : presses))
        return held ? clicks + [.press(button)] : clicks
    }

    private static func clamp(_ delta: Int32) -> Int32 {
        max(-motionLimit, min(motionLimit, delta))
    }
}
