import Foundation
import LumaRemoteCore
import Observation

/// The pointer channel's socket to the TV.
public protocol DatagramSocket: Sendable {
    func send(_ datagram: Data)
    func close()
}

/// Everything the remote screen shows and does: the paired TVs, the session with the chosen one, keys,
/// text, LumaTV actions, the pointer channel, pairing and diagnostics.
@MainActor
@Observable
public final class RemoteModel {
    /// The outside world: `.live()` on a device, fakes in tests and previews.
    public struct Services: Sendable {
        public var store: any PairingStore
        public var connect: Connector
        public var browse: @Sendable () -> AsyncStream<DiscoveryEvent>
        /// Opens a datagram socket to the TV; `receive` gets what comes back.
        public var datagrams: @Sendable (_ host: String, _ port: UInt16, _ receive: @escaping @Sendable (Data) -> Void) -> any DatagramSocket
        public var wake: @Sendable (_ mac: String, _ host: String) async -> Void

        public init(
            store: any PairingStore,
            connect: @escaping Connector,
            browse: @escaping @Sendable () -> AsyncStream<DiscoveryEvent>,
            datagrams: @escaping @Sendable (_ host: String, _ port: UInt16, _ receive: @escaping @Sendable (Data) -> Void) -> any DatagramSocket,
            wake: @escaping @Sendable (_ mac: String, _ host: String) async -> Void
        ) {
            self.store = store
            self.connect = connect
            self.browse = browse
            self.datagrams = datagrams
            self.wake = wake
        }
    }

    public enum Connection: Sendable, Equatable {
        /// No TV is paired or chosen.
        case none
        case connecting
        case connected
        /// The TV is off or out of reach; retrying.
        case offline
        /// The TV's messages could not be decoded; `incompatibility` has the error.
        case incompatible
        /// The TV removed this phone, so it has to pair again.
        case unpaired
    }

    /// A short message for the person: something the TV refused, or why something failed.
    public struct Notice: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let text: String
    }

    public struct Latency: Sendable, Equatable {
        /// Frames over the encrypted session.
        public var session: LatencySummary?
        /// Pointer-channel datagrams.
        public var datagram: LatencySummary?
    }

    public let settings: RemoteSettings
    /// Air mouse and touchpad motion go out through this.
    public let pointer = PointerSender()
    public private(set) var tvs: [PairedTV] = []
    public private(set) var current: PairedTV?
    public private(set) var connection = Connection.none
    public private(set) var state = TVState()
    /// The decode error behind `.incompatible`, for Diagnostics.
    public private(set) var incompatibility: String?
    /// The TV theme's accent as `#rrggbb`, once a session is open.
    public private(set) var tvAccent: String?
    public private(set) var discovered: [TVAdvertisement] = []
    /// iOS refused Local Network access, so no TV can be found or reached.
    public private(set) var localNetworkDenied = false
    public private(set) var notice: Notice?
    /// A pairing link the host received, waiting for the person to confirm.
    public var invite: PairingInvite?

    private let services: Services
    private let app: String
    @ObservationIgnored private var link: TVLink?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var browser: Task<Void, Never>?
    @ObservationIgnored private var socket: (any DatagramSocket)?
    private let sealer = Locked<DatagramSealer?>(nil)
    @ObservationIgnored private var presses: [RemoteKey: (press: KeyPress, timer: Task<Void, Never>?)] = [:]
    @ObservationIgnored private var pongs: [UInt32: CheckedContinuation<Duration, any Error>] = [:]
    @ObservationIgnored private var pingNumber: UInt32 = 0
    private let epoch = ContinuousClock.now
    @ObservationIgnored private var active = false

    /// `app` names the host and its version, such as `Marquee 0.1.21`; the TV lists it beside the phone.
    public init(app: String, services: Services, settings: RemoteSettings = RemoteSettings()) {
        self.app = app
        self.services = services
        self.settings = settings
    }

    private var phone: PhoneInfo {
        PhoneInfo(name: settings.phoneName, model: PhoneInfo.hardwareModel, app: app)
    }

    // MARK: Lifecycle

    /// Loads the paired TVs, connects to the one used last and starts looking for TVs. The remote screen
    /// calls it when it appears and when the app returns to the foreground.
    public func activate() {
        guard !active else { return }
        active = true
        reload()
        if current == nil {
            current = tvs.first { $0.id.description == settings.lastTV } ?? tvs.last
        }
        browse()
        connect()
    }

    /// Ends the session and the search. The remote screen calls it when it closes or the app leaves the
    /// foreground.
    public func deactivate() {
        guard active else { return }
        active = false
        browser?.cancel()
        browser = nil
        disconnect()
        connection = current == nil ? .none : .offline
    }

    // MARK: TVs

    public func select(_ tv: PairedTV) {
        current = tvs.first { $0.id == tv.id } ?? tv
        settings.lastTV = tv.id.description
        connect()
    }

    /// Removes the TV and its key from this phone. The TV keeps listing the phone until it is removed there.
    public func forget(_ tv: PairedTV) {
        do {
            try services.store.remove(tv.id)
        } catch {
            show(Self.message(for: error))
        }
        reload()
        if current?.id == tv.id {
            current = tvs.last
            settings.lastTV = current?.id.description
            connect()
        }
    }

    /// Takes a `lumaremote://pair` link, as the TV's QR code carries; false when it is not one.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let invite = PairingInvite(url: url) else { return false }
        self.invite = invite
        return true
    }

    /// Pairs by the TV's link and switches to that TV.
    public func pair(_ invite: PairingInvite, phoneName: String) async throws {
        try await pair(address: .host(invite.host, port: invite.port), tv: invite.tv, code: invite.code, phoneName: phoneName)
        if self.invite == invite { self.invite = nil }
    }

    /// Pairs with a TV found on the network by the code it shows.
    public func pair(_ advertisement: TVAdvertisement, code: PairingCode, phoneName: String) async throws {
        try await pair(address: .service(name: advertisement.service), tv: advertisement.id, code: code, phoneName: phoneName)
    }

    private func pair(address: TVAddress, tv id: TVID, code: PairingCode, phoneName: String) async throws {
        settings.phoneName = phoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tv = try await Pairing.pair(address: address, tv: id, code: code, phone: phone, connect: services.connect)
        try services.store.save(tv)
        reload()
        select(tv)
    }

    private func reload() {
        do {
            tvs = try services.store.all()
        } catch {
            show(Self.message(for: error))
        }
    }

    /// Updates the chosen TV's stored record.
    private func remember(_ change: (inout PairedTV) -> Void) {
        guard var tv = current else { return }
        let before = tv
        change(&tv)
        guard tv != before else { return }
        current = tv
        if let index = tvs.firstIndex(where: { $0.id == tv.id }) { tvs[index] = tv }
        try? services.store.save(tv)
    }

    private func browse() {
        browser?.cancel()
        let events = services.browse()
        browser = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .found(let found):
                    self.discovered = found
                    self.localNetworkDenied = false
                    // The Bonjour name still finds the TV after its address changes.
                    if let current = self.current, let seen = found.first(where: { $0.id == current.id }) {
                        self.remember { $0.service = seen.service }
                    }
                case .denied:
                    self.localNetworkDenied = true
                }
            }
        }
    }

    // MARK: Session

    private func connect() {
        disconnect()
        guard active, let tv = current else {
            connection = .none
            return
        }
        let link = TVLink(tv: tv, phone: phone, connect: services.connect)
        self.link = link
        connection = .connecting
        listener = Task { [weak self] in
            await link.start()
            for await event in link.events {
                self?.handle(event, from: link)
            }
        }
    }

    private func disconnect() {
        listener?.cancel()
        listener = nil
        releasePresses()
        closeDatagrams()
        if let link {
            Task { await link.stop() }
        }
        link = nil
        state = TVState()
        tvAccent = nil
    }

    private func handle(_ event: TVLink.Event, from source: TVLink) {
        guard source === link else { return }
        switch event {
        case .status(let status):
            switch status {
            case .connecting: connection = .connecting
            case .connected: connection = .connected; incompatibility = nil
            case .offline: connection = .offline; incompatibility = nil
            case .incompatible(let detail): connection = .incompatible; incompatibility = detail
            case .rejected, .revoked: connection = .unpaired; incompatibility = nil
            case .stopped: return
            }
            if status != .connected {
                releasePresses()
                closeDatagrams()
            }
        case .welcome(let welcome):
            var fresh = TVState()
            fresh.apply(welcome.state)
            state = fresh
            tvAccent = welcome.tv.accent
            remember {
                $0.name = welcome.tv.name
                if !welcome.tv.mac.isEmpty { $0.mac = welcome.tv.mac }
            }
            openDatagrams(welcome.udp)
        case .state(let update):
            state.apply(update)
        case .refused(let code, _):
            show(Self.message(forCode: code))
        case .reached(let host, let port):
            remember {
                $0.host = host
                $0.port = port
            }
        }
    }

    private func openDatagrams(_ grant: UDPGrant) {
        closeDatagrams()
        guard let tv = current, !tv.host.isEmpty else { return }
        let sealer = self.sealer
        sealer.withLock { $0 = DatagramSealer(grant: grant) }
        let socket = services.datagrams(tv.host, tv.port) { [weak self] datagram in
            guard let pong = sealer.withLock({ $0?.pong(datagram) }) else { return }
            Task { @MainActor in self?.received(pong) }
        }
        self.socket = socket
        pointer.attach { report in
            guard let datagram = sealer.withLock({ try? $0?.pointer(report) }) else { return }
            socket.send(datagram)
        }
    }

    private func closeDatagrams() {
        pointer.attach(nil)
        socket?.close()
        socket = nil
        sealer.withLock { $0 = nil }
        let waiting = pongs
        pongs = [:]
        for continuation in waiting.values { continuation.resume(throwing: TVLink.RequestError.disconnected) }
    }

    // MARK: Keys and text

    /// Sends a message at once; false, with a notice, when no session is open.
    @discardableResult
    public func send(_ message: ClientMessage) -> Bool {
        guard let link, link.send(message) else {
            show(connection == .unpaired ? "Pair with the TV again to use it." : "Not connected to the TV.")
            return false
        }
        return true
    }

    /// The phone's own volume buttons: 0.5 steps of the receiver's level when the TV offers it, else the TV's key.
    public func volumeButton(_ key: RemoteKey) {
        guard key == .volumeUp || key == .volumeDown,
              let volume = state.volume, volume.via == "receiver", let level = volume.level, let ceiling = volume.max,
              state.allows(.volume(level: 0))
        else { return tap(key) }
        let target = min(max(level + (key == .volumeUp ? 0.5 : -0.5), 0), ceiling)
        guard target != level else { return }
        // Optimistic, so quick presses accumulate before the TV's state arrives.
        state.volume?.level = target
        Task { await perform(.volume(level: target)) }
    }

    public func tap(_ key: RemoteKey) {
        send(.key(key, .tap))
    }

    /// A finger went down on a key: released quickly it taps, held it repeats or long-presses.
    public func pressBegan(_ key: RemoteKey) {
        guard presses[key] == nil else { return }
        let press = KeyPress(key)
        var timer: Task<Void, Never>?
        if let threshold = press.threshold {
            timer = Task { [weak self] in
                try? await Task.sleep(for: threshold)
                guard !Task.isCancelled else { return }
                self?.thresholdPassed(key)
            }
        }
        presses[key] = (press, timer)
    }

    public func pressEnded(_ key: RemoteKey) {
        guard let entry = presses.removeValue(forKey: key) else { return }
        entry.timer?.cancel()
        if let message = entry.press.released() { send(message) }
    }

    /// The finger slid off the key: nothing is pressed, but a key that went down comes up.
    public func pressCancelled(_ key: RemoteKey) {
        guard let entry = presses.removeValue(forKey: key) else { return }
        entry.timer?.cancel()
        if let message = entry.press.cancelled() { send(message) }
    }

    private func thresholdPassed(_ key: RemoteKey) {
        guard var entry = presses[key] else { return }
        let message = entry.press.thresholdPassed()
        presses[key] = entry
        if let message { send(message) }
    }

    private func releasePresses() {
        for entry in presses.values { entry.timer?.cancel() }
        presses = [:]
    }

    /// The power key while a session is open, which the TV keeps in standby; otherwise a wake packet to
    /// the TV's last address and an immediate reconnect.
    public func power() {
        if connection == .connected { tap(.power) } else { wake() }
    }

    public func wake() {
        guard let tv = current else { return }
        if !tv.mac.isEmpty, !tv.host.isEmpty {
            let wake = services.wake
            Task { await wake(tv.mac, tv.host) }
        }
        if connection == .unpaired || link == nil {
            connect()
        } else if let link {
            Task { await link.start() }
        }
    }

    /// Sends the change from the text the TV has to what the phone's field holds now.
    public func type(from old: String, to new: String) {
        for message in TextDiff.messages(from: old, to: new) {
            guard send(message) else { return }
        }
    }

    public func edit(_ operation: EditOperation) {
        send(.edit(operation))
    }

    // MARK: LumaTV

    /// Runs a LumaTV action; false, with a notice, when it fails.
    @discardableResult
    public func perform(_ action: TVAction) async -> Bool {
        guard let link else {
            show("Not connected to the TV.")
            return false
        }
        do {
            try await link.perform(action)
            return true
        } catch {
            show(Self.message(for: error))
            return false
        }
    }

    /// A whole list from the TV; nil, with a notice, when it fails.
    public func list(_ kind: ListKind) async -> [ListItem]? {
        guard let link else {
            show("Not connected to the TV.")
            return nil
        }
        do {
            return try await link.list(kind)
        } catch {
            show(Self.message(for: error))
            return nil
        }
    }

    // MARK: Diagnostics

    /// Round trips over the session and the pointer channel, one after another.
    public func measureLatency(samples: Int = 20) async -> Latency {
        var session: [Duration] = []
        var datagram: [Duration] = []
        for _ in 0..<samples {
            guard let link else { break }
            if let time = try? await link.roundTrip() { session.append(time) }
            if let time = try? await datagramRoundTrip() { datagram.append(time) }
        }
        return Latency(session: LatencySummary(session), datagram: LatencySummary(datagram))
    }

    private func datagramRoundTrip() async throws -> Duration {
        guard let socket else { throw TVLink.RequestError.notConnected }
        pingNumber &+= 1
        let number = pingNumber
        let time = UInt64((ContinuousClock.now - epoch) / .nanoseconds(1))
        guard let datagram = sealer.withLock({ try? $0?.ping(id: number, time: time) }) else {
            throw TVLink.RequestError.notConnected
        }
        return try await withCheckedThrowingContinuation { continuation in
            pongs[number] = continuation
            socket.send(datagram)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.pongs.removeValue(forKey: number)?.resume(throwing: TVLink.RequestError.timedOut)
            }
        }
    }

    private func received(_ pong: PingBody) {
        guard let continuation = pongs.removeValue(forKey: pong.id) else { return }
        continuation.resume(returning: (ContinuousClock.now - epoch) - .nanoseconds(Int64(clamping: pong.time)))
    }

    // MARK: Notices

    public func dismissNotice() {
        notice = nil
    }

    private func show(_ text: String) {
        notice = Notice(id: UUID(), text: text)
    }

    /// Plain words for an error from pairing, the session or an action.
    public static func message(for error: any Error) -> String {
        switch error {
        case PairingError.wrongCode:
            return "That code didn't work. Check the code on the TV and try again."
        case PairingError.refused(let code):
            return message(forCode: code)
        case PairingError.unexpectedReply:
            return "The TV answered in a way this app doesn't understand. Update the app or the TV."
        case StreamError.unreachable, StreamError.timedOut:
            return "Couldn't reach the TV. Check that the phone is on the same Wi-Fi."
        case StreamError.closed, HandshakeError.refused, HandshakeError.authenticationFailed:
            return "The TV closed the connection."
        case TVLink.RequestError.failed(let code):
            return message(forCode: code)
        case TVLink.RequestError.notConnected, TVLink.RequestError.disconnected:
            return "Not connected to the TV."
        case TVLink.RequestError.timedOut:
            return "The TV didn't answer in time."
        default:
            return "Something went wrong: \(error.localizedDescription)"
        }
    }

    /// Plain words for one of the TV's error codes.
    public static func message(forCode code: String) -> String {
        switch code {
        case "standby": "The TV is in standby. Turn it on first."
        case "no-field": "There's no text box open on the TV."
        case "off": "That needs a LumaTV plugin that's switched off."
        case "not-found": "The TV couldn't find that."
        case "unavailable": "LumaTV isn't running on the TV right now."
        case "rate": "Too much at once. Slow down a little."
        case "too-long": "That text is too long for the TV."
        default: "The TV refused that (\(code))."
        }
    }
}
