import Foundation

public enum LumaRemote {
    /// The kit's version, sent in `hello`.
    public static let version = "1.0.3"
}

/// Connects to a TV address: TCP in the app, a pipe to the fake TV in tests.
public typealias Connector = @Sendable (TVAddress) async throws -> any ByteStream

public enum PairingError: Error, Equatable {
    /// The TV closed the connection without answering: a wrong or expired code, which uses one of the
    /// pairing window's five tries.
    case wrongCode
    /// The TV answered with an error code.
    case refused(String)
    case unexpectedReply
}

public enum Pairing {
    /// Pairs with a TV whose pairing window is open. `address` is the link's host or the TV's Bonjour
    /// instance; `tv` and `code` come from the link or from discovery and the typed code.
    public static func pair(
        address: TVAddress,
        tv: TVID,
        code: PairingCode,
        phone: PhoneInfo,
        connect: Connector
    ) async throws -> PairedTV {
        // PBKDF2 at 131,072 iterations takes a noticeable moment, so not on the caller's actor.
        let key = await Task.detached(priority: .userInitiated) { PairingKey.derive(code: code, tv: tv) }.value
        let stream = try await connect(address)
        defer { stream.close() }
        let channel: SecureChannel
        do {
            channel = try await withDeadline(.seconds(5), onTimeout: { stream.close() }) {
                try await SecureChannel.open(stream, mode: .pairing, psk: key)
            }
        } catch HandshakeError.refused, HandshakeError.authenticationFailed {
            throw PairingError.wrongCode
        }
        try channel.send(.pair(phone))
        let reply = try await withDeadline(.seconds(10), onTimeout: { stream.close() }) {
            try await channel.receive()
        }
        switch reply {
        case .paired(let grant):
            guard grant.tv.id == tv, grant.key.count == 32 else { throw PairingError.unexpectedReply }
            let reached = stream.remoteAddress
            var host = reached?.host
            var port = reached?.port
            if case .host(let linkHost, let linkPort) = address {
                host = host ?? linkHost
                port = port ?? linkPort
            }
            var service: String?
            if case .service(let name) = address { service = name }
            return PairedTV(
                id: grant.tv.id, name: grant.tv.name, mac: grant.tv.mac, device: grant.device, key: grant.key,
                host: host ?? "", port: port ?? PairingInvite.defaultPort, service: service
            )
        case .error(let code, _):
            throw PairingError.refused(code)
        default:
            throw PairingError.unexpectedReply
        }
    }
}

/// One paired TV's session: connects, says hello, keeps the session alive, reconnects with backoff, and
/// reports what the TV says. Keys and text go out through `send` from any thread without waiting.
public actor TVLink {
    public enum Status: Sendable, Equatable {
        case connecting
        case connected
        /// Not reachable right now; retrying.
        case offline
        /// The TV sent a message this kit cannot decode; the detail is the decode error. Retrying.
        case incompatible(String)
        /// The TV refused this phone's key three times running: it was removed while the phone was away.
        case rejected
        /// The TV removed this phone during the session.
        case revoked
        case stopped
    }

    public enum Event: Sendable {
        case status(Status)
        case welcome(Welcome)
        case state(TVStateUpdate)
        /// A `key`, `text` or `edit` the TV refused.
        case refused(code: String, about: String?)
        /// The address the session reached, worth keeping for the next connection and Wake-on-LAN.
        case reached(host: String, port: UInt16)
    }

    public enum RequestError: Error, Equatable {
        case notConnected
        /// The TV's `done` error code, such as `off` or `not-found`.
        case failed(String)
        case disconnected
        case timedOut
    }

    public nonisolated let events: AsyncStream<Event>
    public nonisolated let tvID: TVID
    private nonisolated let continuation: AsyncStream<Event>.Continuation
    private nonisolated let channel = Locked<SecureChannel?>(nil)
    private nonisolated let liveStream = Locked<(any ByteStream)?>(nil)

    private var tv: PairedTV
    private let phone: PhoneInfo
    private let connect: Connector
    private var runner: Task<Void, Never>?
    private let stableAfter: Duration
    /// When the current session reached the TV's welcome; nil until it does.
    private var establishedAt: ContinuousClock.Instant?
    private var nextID: UInt32 = 0
    private var actions: [UInt32: CheckedContinuation<Void, Error>] = [:]
    private var lists: [UInt32: (items: [ListItem], continuation: CheckedContinuation<[ListItem], Error>)] = [:]
    private var pings: [UInt32: (sent: ContinuousClock.Instant, continuation: CheckedContinuation<Duration, Error>)] = [:]

    static let keepalive: Duration = .milliseconds(1500)
    static let silence: Duration = .seconds(6)
    static let requestTimeout: Duration = .seconds(10)

    public init(tv: PairedTV, phone: PhoneInfo, connect: @escaping Connector) {
        self.init(tv: tv, phone: phone, stableAfter: Self.silence, connect: connect)
    }

    /// `stableAfter` is how long an established session must last for its end to count as a lost
    /// connection to a reachable TV rather than a failed attempt. `silence` is the window in which the
    /// keepalive exchange proves a session healthy; a TV that welcomes and drops sooner is backed off.
    init(tv: PairedTV, phone: PhoneInfo, stableAfter: Duration, connect: @escaping Connector) {
        self.tv = tv
        tvID = tv.id
        self.phone = phone
        self.connect = connect
        self.stableAfter = stableAfter
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts connecting, or reconnects at once with the backoff reset, as after a wake.
    public func start() {
        runner?.cancel()
        closeLive()
        runner = Task { await self.run() }
    }

    /// Says goodbye and ends the session for good.
    public func stop() {
        runner?.cancel()
        runner = nil
        if let open = channel.withLock({ $0 }) { try? open.send(.bye) }
        closeLive()
        continuation.yield(.status(.stopped))
        continuation.finish()
    }

    /// Sends a key, text or edit at once; false when no session is open.
    @discardableResult
    public nonisolated func send(_ message: ClientMessage) -> Bool {
        guard let open = channel.withLock({ $0 }) else { return false }
        do {
            try open.send(message)
            return true
        } catch {
            return false
        }
    }

    public nonisolated var isConnected: Bool { channel.withLock { $0 != nil } }

    /// Path of the authenticated session only; never a pending or failed connection.
    public nonisolated var connectionPath: ConnectionPath? {
        channel.withLock { $0?.stream.connectionPath }
    }

    /// Runs a LumaTV action and waits for the TV's `done`.
    public func perform(_ action: TVAction) async throws {
        let open = try openChannel()
        let id = makeID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            actions[id] = continuation
            sendRequest(.act(id: id, action), id: id, on: open)
        }
    }

    /// One whole list, however many pages it takes.
    public func list(_ kind: ListKind) async throws -> [ListItem] {
        let open = try openChannel()
        let id = makeID()
        return try await withCheckedThrowingContinuation { continuation in
            lists[id] = ([], continuation)
            sendRequest(.get(id: id, kind), id: id, on: open)
        }
    }

    /// One `ping` frame's round trip, for Diagnostics.
    public func roundTrip() async throws -> Duration {
        let open = try openChannel()
        let id = makeID()
        return try await withCheckedThrowingContinuation { continuation in
            pings[id] = (.now, continuation)
            sendRequest(.ping(id), id: id, on: open)
        }
    }

    // MARK: Session

    private func run() async {
        var failures = 0
        var refusals = 0
        var undecodable: String?
        continuation.yield(.status(.connecting))
        while !Task.isCancelled {
            establishedAt = nil
            do {
                // Only ever ends by throwing.
                try await session()
            } catch SessionEnd.revoked {
                continuation.yield(.status(.revoked))
                return
            } catch HandshakeError.refused {
                refusals += 1
                failures += 1
                if refusals >= 3 {
                    continuation.yield(.status(.rejected))
                    return
                }
            } catch SessionEnd.undecodable(let detail) {
                undecodable = detail
                failures += 1
            } catch {
                undecodable = nil
                if let since = establishedAt, ContinuousClock.now - since >= stableAfter {
                    // The TV was reachable and the session healthy, so this is a new connection, not a failing one.
                    failures = 0
                    refusals = 0
                } else {
                    failures += 1
                }
            }
            guard !Task.isCancelled else { return }
            continuation.yield(.status(failures == 0 ? .connecting : (undecodable.map { Status.incompatible($0) } ?? .offline)))
            // Never a tight loop: a re-dial after a healthy session still waits the first step.
            try? await Task.sleep(for: Self.backoff(after: max(failures, 1)))
        }
    }

    /// 250 ms doubling to 8 s.
    static func backoff(after failures: Int) -> Duration {
        .milliseconds(250 * (1 << min(failures - 1, 5)))
    }

    private enum SessionEnd: Error {
        case revoked
        case unexpectedReply
        case undecodable(String)
    }

    private static func receive(_ open: SecureChannel) async throws -> ServerMessage {
        do {
            return try await open.receive()
        } catch let error as DecodingError {
            throw SessionEnd.undecodable(Self.describe(error))
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \(key.stringValue) at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default: return "\(error)"
        }
    }

    private func session() async throws {
        let stream = try await connectAny()
        liveStream.withLock { $0 = stream }
        defer { closeLive() }
        let key = tv.key
        let open = try await withDeadline(.seconds(3), onTimeout: { stream.close() }) {
            try await SecureChannel.open(stream, mode: .session, psk: key)
        }
        try open.send(.hello(phone, kit: "LumaRemoteKit \(LumaRemote.version)"))
        let first = try await withDeadline(.seconds(3), onTimeout: { stream.close() }) {
            try await Self.receive(open)
        }
        switch first {
        case .welcome(let welcome):
            channel.withLock { $0 = open }
            establishedAt = .now
            if let reached = stream.remoteAddress {
                tv.host = reached.host
                tv.port = reached.port
                continuation.yield(.reached(host: reached.host, port: reached.port))
            }
            continuation.yield(.welcome(welcome))
            continuation.yield(.status(.connected))
        case .revoked:
            throw SessionEnd.revoked
        default:
            throw SessionEnd.unexpectedReply
        }
        let lastHeard = Locked(ContinuousClock.now)
        let keeper = Task {
            var number: UInt32 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if ContinuousClock.now - lastHeard.withLock({ $0 }) > Self.silence {
                    open.close()
                    return
                }
                if open.idleTime >= Self.keepalive {
                    // Keepalive pings count down from the top so they never meet a request's id.
                    number &+= 1
                    try? open.send(.ping(UInt32.max - number))
                }
            }
        }
        defer {
            keeper.cancel()
            channel.withLock { $0 = nil }
            failPending()
        }
        while true {
            let message = try await Self.receive(open)
            lastHeard.withLock { $0 = .now }
            try handle(message)
        }
    }

    /// The last address first, then the Bonjour instance, which still works after the TV's address changed.
    private func connectAny() async throws -> any ByteStream {
        var addresses: [TVAddress] = []
        if !tv.host.isEmpty { addresses.append(.host(tv.host, port: tv.port)) }
        if let service = tv.service { addresses.append(.service(name: service)) }
        var lastError: any Error = StreamError.unreachable("no address")
        for address in addresses {
            do {
                return try await connect(address)
            } catch {
                lastError = error
                if Task.isCancelled { break }
            }
        }
        throw lastError
    }

    private func handle(_ message: ServerMessage) throws {
        switch message {
        case .state(let update):
            continuation.yield(.state(update))
        case .done(let id, let error):
            guard let waiting = actions.removeValue(forKey: id) else { return }
            if let error { waiting.resume(throwing: RequestError.failed(error)) } else { waiting.resume() }
        case .list(let page):
            guard var waiting = lists.removeValue(forKey: page.id) else { return }
            waiting.items += page.items
            if page.more { lists[page.id] = waiting } else { waiting.continuation.resume(returning: waiting.items) }
        case .pong(let number):
            guard let waiting = pings.removeValue(forKey: number) else { return }
            waiting.continuation.resume(returning: .now - waiting.sent)
        case .error(let code, let about):
            continuation.yield(.refused(code: code, about: about))
        case .revoked:
            throw SessionEnd.revoked
        case .welcome, .paired, .unknown:
            break
        }
    }

    // MARK: Requests

    private func openChannel() throws -> SecureChannel {
        guard let open = channel.withLock({ $0 }) else { throw RequestError.notConnected }
        return open
    }

    private func makeID() -> UInt32 {
        nextID = nextID % 0x7FFF_FFFF + 1
        return nextID
    }

    private func sendRequest(_ message: ClientMessage, id: UInt32, on open: SecureChannel) {
        do {
            try open.send(message)
        } catch {
            fail(id, with: error)
            return
        }
        Task {
            try? await Task.sleep(for: Self.requestTimeout)
            self.fail(id, with: RequestError.timedOut)
        }
    }

    private func fail(_ id: UInt32, with error: any Error) {
        actions.removeValue(forKey: id)?.resume(throwing: error)
        lists.removeValue(forKey: id)?.continuation.resume(throwing: error)
        pings.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }

    private func failPending() {
        for id in Array(actions.keys) + Array(lists.keys) + Array(pings.keys) {
            fail(id, with: RequestError.disconnected)
        }
    }

    private nonisolated func closeLive() {
        liveStream.withLock { stream in
            stream?.close()
            stream = nil
        }
        channel.withLock { $0 = nil }
    }
}

/// Seals one session's pointer and ping datagrams and opens its pongs.
public struct DatagramSealer: Sendable {
    public let grant: UDPGrant
    private var sequence: UInt32 = 0
    private var lastPong: UInt32 = 0

    public init(grant: UDPGrant) {
        self.grant = grant
    }

    public mutating func pointer(_ report: PointerReport) throws -> Data {
        try seal(.pointer, report.bytes)
    }

    public mutating func ping(id: UInt32, time: UInt64) throws -> Data {
        try seal(.ping, PingBody(id: id, time: time).bytes)
    }

    /// Nil for anything but a fresh, authentic pong of this session.
    public mutating func pong(_ datagram: Data) -> PingBody? {
        guard let (header, body) = try? Datagram.open(datagram, key: grant.key, direction: .tvToPhone),
              header.kind == .pong, header.session == grant.session, header.sequence > lastPong
        else { return nil }
        lastPong = header.sequence
        return PingBody(body)
    }

    private mutating func seal(_ kind: Datagram.Kind, _ body: Data) throws -> Data {
        sequence += 1
        return try Datagram.seal(Datagram.Header(kind: kind, session: grant.session, sequence: sequence),
                                 body: body, key: grant.key, direction: .phoneToTV)
    }
}

/// Paces pointer datagrams: one per motion sample, at most 120 a second; one at once on any change of
/// buttons, centre or flags, with copies 5 and 20 ms later; and one every 250 ms while engaged or while a
/// button is held. Totals start again with each session.
public final class PointerSender: @unchecked Sendable {
    static let gap = DispatchTimeInterval.microseconds(8_333)
    static let copies: [DispatchTimeInterval] = [.milliseconds(5), .milliseconds(20)]
    static let keepalive = DispatchTimeInterval.milliseconds(250)

    private let queue = DispatchQueue(label: "LumaRemote.pointer", qos: .userInteractive)
    // Touched only on `queue`.
    private var accumulator = PointerAccumulator()
    private var output: (@Sendable (PointerReport) -> Void)?
    private var lastSent: DispatchTime?
    private var motionPending = false
    private var keeper: DispatchSourceTimer?

    public init() {}

    /// A new session's output, or nil when there is none; the totals start from zero.
    public func attach(_ output: (@Sendable (PointerReport) -> Void)?) {
        queue.async {
            self.accumulator = PointerAccumulator()
            self.output = output
            self.lastSent = nil
            self.updateKeeper()
        }
    }

    /// The totals so far, for tests and Diagnostics.
    public var report: PointerReport { queue.sync { accumulator.report } }

    public func move(dx: Double, dy: Double) {
        queue.async {
            self.accumulator.move(dx: dx, dy: dy)
            self.motion()
        }
    }

    public func scroll(dx: Double, dy: Double) {
        queue.async {
            self.accumulator.scroll(dx: dx, dy: dy)
            self.motion()
        }
    }

    public func press(_ button: PointerButton) { discrete { $0.press(button) } }
    public func release(_ button: PointerButton) { discrete { $0.release(button) } }
    public func click(_ button: PointerButton) { discrete { $0.click(button) } }
    public func centre() { discrete { $0.centre() } }
    public func set(_ flag: PointerReport.Flags, _ on: Bool) {
        discrete { accumulator in
            guard accumulator.report.flags.contains(flag) != on else { return }
            accumulator.set(flag, on)
        }
    }

    private func discrete(_ change: @escaping @Sendable (inout PointerAccumulator) -> Void) {
        queue.async {
            let before = self.accumulator.report
            change(&self.accumulator)
            guard self.accumulator.report != before else { return }
            self.flush()
            for delay in Self.copies {
                self.queue.asyncAfter(deadline: .now() + delay) { self.flush() }
            }
            self.updateKeeper()
        }
    }

    private func motion() {
        let now = DispatchTime.now()
        guard let lastSent, now < lastSent + Self.gap else {
            flush()
            return
        }
        guard !motionPending else { return }
        motionPending = true
        queue.asyncAfter(deadline: lastSent + Self.gap) {
            self.motionPending = false
            self.flush()
        }
    }

    private func flush() {
        guard let output else { return }
        lastSent = .now()
        output(accumulator.report)
    }

    private func updateKeeper() {
        let report = accumulator.report
        let needed = output != nil && (report.flags.contains(.engaged) || !report.held.isEmpty)
        if needed, keeper == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.keepalive, repeating: Self.keepalive)
            timer.setEventHandler { [unowned self] in self.flush() }
            timer.resume()
            keeper = timer
        } else if !needed, let timer = keeper {
            timer.cancel()
            keeper = nil
        }
    }
}
