import Foundation
import LumaRemoteCore

/// A LumaTV that speaks protocol version 1 on loopback, for tests and simulator runs: it pairs with a
/// fixed code, opens sessions, answers actions and lists, and logs what arrived in a readable form
/// (`key volup tap`, `text hello`, `act settings`, `pointer click left`).
public actor FakeTV {
    public struct Configuration: Sendable {
        public var id = TVID("5a1c0ffee0ddba11")!
        public var name = "Living Room TV"
        public var mac = "74:c1:7e:bd:ae:30"
        public var accent = "#c8a2ff"
        public var code = PairingCode("LUMA2345")!
        /// Whether a pairing window is open.
        public var pairingOpen = true
        public var foreground = "com.beb.plxnative"
        public var actions = ["home", "quick", "settings", "notifications", "input", "pictureoff", "cameras", "camera",
                              "camera-close", "guide", "tune", "launch", "volume", "power"]
        public var apps: [(id: String, title: String)] = [("youtube.leanback.v4", "YouTube"), ("netflix", "Netflix"),
                                                          ("com.beb.plxnative", "Marquee")]
        public var channels: [(id: String, number: String, name: String)] = [("c1", "1", "BBC One"), ("c2", "2", "BBC Two")]
        public var cameras: [(id: String, name: String)] = [("front", "Front door"), ("garden", "Garden")]

        /// Leaves `tv` out of the welcome, which no phone can decode.
        public var undecodableWelcome = false

        public init() {}
    }

    public private(set) var configuration: Configuration
    /// Everything the phones sent, oldest first.
    public private(set) var log: [String] = []
    /// Paired phones: device id to session key.
    public private(set) var phones: [String: Data] = [:]

    private var sessions: [UInt32: Session] = [:]
    private var pointers: [UInt32: PointerState] = [:]
    private var pairingKey: Data?
    private var power = "on"
    private var ime: [String: Any] = ["active": false]
    private var volume: [String: Any] = ["via": "receiver", "level": 30, "max": 100, "muted": false]
    private var waiters: [(predicate: @Sendable (String) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    public init(_ configuration: Configuration = Configuration(), phones: [String: Data] = [:]) {
        self.configuration = configuration
        self.phones = phones
    }

    /// The link the TV's QR code would carry for `host` and `port`.
    public func pairingLink(host: String, port: UInt16) -> URL {
        PairingInvite(host: host, port: port, tv: configuration.id, code: configuration.code).url
    }

    /// Waits until the log holds an entry that satisfies `predicate`.
    public func waitFor(_ predicate: @escaping @Sendable (String) -> Bool) async {
        if log.contains(where: predicate) { return }
        await withCheckedContinuation { continuation in
            waiters.append((predicate, continuation))
        }
    }

    public func clearLog() {
        log.removeAll()
    }

    // MARK: TV-side changes

    /// Puts a text field in front, or takes it away, as the shell would report it.
    public func setTextField(active: Bool, purpose: Int = 0, enter: Int = 0) {
        ime = active ? ["active": true, "owner": "app", "purpose": purpose, "hint": 0, "enter": enter, "max": 0, "text": false]
            : ["active": false]
        broadcast(["t": "state", "ime": ime])
    }

    /// Replaces the volume and ime members exactly as given, to send shapes a real TV might.
    public func setWire(volume: [String: Any]? = nil, ime: [String: Any]? = nil) {
        var update: [String: Any] = ["t": "state"]
        if let volume { self.volume = volume; update["volume"] = volume }
        if let ime { self.ime = ime; update["ime"] = ime }
        broadcast(update)
    }

    public func setPower(standby: Bool) {
        power = standby ? "standby" : "on"
        broadcast(["t": "state", "power": power])
    }

    /// Removes a phone: its sessions get `revoked` and close.
    public func revoke(device: String) {
        phones[device] = nil
        for (id, session) in sessions where session.device == device {
            session.send(["t": "revoked"])
            session.close()
            sessions[id] = nil
        }
    }

    // MARK: Connections

    /// Serves one TCP connection to the end.
    public func serve(_ stream: any ByteStream) async {
        defer { stream.close() }
        guard let preamble = try? await stream.receive(exactly: 6),
              preamble.prefix(5) == Data([0x4C, 0x52, 0x4D, 0x54, 1]),
              let mode = Preamble.Mode(rawValue: preamble[preamble.startIndex + 5]),
              let first = try? await stream.receive(exactly: NoiseHandshake.messageLength)
        else { return }
        switch mode {
        case .pairing:
            guard configuration.pairingOpen, let opened = await respond(stream, preamble: preamble, first: first, keys: [("", currentPairingKey())]) else { return }
            await pairing(opened.channel)
        case .session:
            guard let opened = await respond(stream, preamble: preamble, first: first, keys: phones.map { ($0.key, $0.value) }) else { return }
            await session(opened.channel, device: opened.device)
        }
    }

    private func currentPairingKey() -> Data {
        if let pairingKey { return pairingKey }
        let key = PairingKey.derive(code: configuration.code, tv: configuration.id)
        pairingKey = key
        return key
    }

    /// Tries each key on message 1, as the TV does; nil closes without answering.
    private func respond(_ stream: any ByteStream, preamble: Data, first: Data, keys: [(String, Data)]) async -> (channel: Session, device: String)? {
        for (device, key) in keys {
            var handshake = NoiseHandshake(role: .responder, prologue: preamble, psk: key)
            guard (try? handshake.readFirst(first)) != nil, let (second, session) = try? handshake.writeSecond() else { continue }
            stream.send(second)
            return (Session(stream: stream, session: session, device: device), device)
        }
        return nil
    }

    private func pairing(_ channel: Session) async {
        guard let message = try? await channel.receive(), message["t"] as? String == "pair",
              let name = message["name"] as? String, (1...40).contains(name.count)
        else {
            channel.send(["t": "error", "code": "bad-message"])
            return
        }
        let device = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).hexString
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        phones[device] = key
        record("pair \(name)")
        channel.send(["t": "paired", "device": device, "key": key.base64EncodedString(),
                      "tv": ["id": configuration.id.description, "name": configuration.name, "mac": configuration.mac]])
        configuration.pairingOpen = false
        pairingKey = nil
    }

    private func session(_ channel: Session, device: String) async {
        guard let hello = try? await channel.receive(), hello["t"] as? String == "hello" else { return }
        record("hello \(hello["name"] as? String ?? "")")
        let udpSession = UInt32.random(in: 1...UInt32.max)
        let udpKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        sessions[udpSession] = channel
        pointers[udpSession] = PointerState(key: udpKey)
        defer {
            sessions[udpSession] = nil
            pointers[udpSession] = nil
        }
        var welcome: [String: Any] = [
            "t": "welcome", "v": 1, "device": device,
            "tv": ["id": configuration.id.description, "name": configuration.name, "mac": configuration.mac, "accent": configuration.accent],
            "udp": ["session": udpSession, "key": udpKey.base64EncodedString()],
            "state": ["power": power, "fg": configuration.foreground, "ime": ime, "volume": volume, "acts": configuration.actions],
        ]
        if configuration.undecodableWelcome { welcome["tv"] = nil }
        channel.send(welcome)
        while let message = try? await channel.receive() {
            if !handle(message, on: channel) { return }
        }
    }

    /// False ends the session.
    private func handle(_ message: [String: Any], on channel: Session) -> Bool {
        switch message["t"] as? String {
        case "key":
            guard let key = message["k"] as? String, RemoteKey(rawValue: key) != nil else {
                channel.send(["t": "error", "code": "bad-key", "about": "key"])
                return true
            }
            if power == "standby" && key != "power" {
                channel.send(["t": "error", "code": "standby", "about": "key"])
                return true
            }
            if key == "power" { setPower(standby: power == "on") }
            record("key \(key) \(message["a"] as? String ?? "")")
        case "text":
            guard ime["active"] as? Bool == true else {
                channel.send(["t": "error", "code": "no-field", "about": "text"])
                return true
            }
            record("text \(message["s"] as? String ?? "")")
        case "edit":
            let count = message["n"].map { " \($0)" } ?? ""
            record("edit \(message["op"] as? String ?? "")\(count)")
        case "act":
            let id = message["id"] as? Int ?? 0
            let action = message["do"] as? String ?? ""
            let argument = ["page", "camera", "channel", "app", "level", "to"].compactMap { name in message[name].map { " \(name)=\($0)" } }.joined()
            record("act \(action)\(argument)")
            if power == "standby" {
                channel.send(["t": "done", "id": id, "error": "standby"])
            } else if configuration.actions.contains(action) {
                channel.send(["t": "done", "id": id])
            } else {
                channel.send(["t": "done", "id": id, "error": "off"])
            }
        case "get":
            let id = message["id"] as? Int ?? 0
            let what = message["what"] as? String ?? ""
            record("get \(what)")
            let items: [[String: Any]] = switch what {
            case "apps": configuration.apps.map { ["id": $0.id, "title": $0.title] }
            case "channels": configuration.channels.map { ["id": $0.id, "no": $0.number, "name": $0.name] }
            case "cameras": configuration.cameras.map { ["id": $0.id, "name": $0.name] }
            default: []
            }
            // Two pages, as a long list would come.
            let half = items.count / 2
            channel.send(["t": "list", "id": id, "what": what, "items": Array(items[..<half]), "more": true])
            channel.send(["t": "list", "id": id, "what": what, "items": Array(items[half...]), "more": false])
        case "ping":
            channel.send(["t": "pong", "n": message["n"] ?? 0])
        case "bye":
            record("bye")
            return false
        default:
            channel.send(["t": "error", "code": "bad-message"])
        }
        return true
    }

    /// One pointer or ping datagram; the answer, if any, goes back to the sender.
    public func receiveDatagram(_ datagram: Data) -> Data? {
        guard datagram.count >= Datagram.Header.length else { return nil }
        let sessionID = datagram.littleEndianUInt32(at: 4)
        guard var state = pointers[sessionID],
              let (header, body) = try? Datagram.open(datagram, key: state.key, direction: .phoneToTV),
              header.session == sessionID, header.sequence > state.lastSequence
        else { return nil }
        state.lastSequence = header.sequence
        defer { pointers[sessionID] = state }
        switch header.kind {
        case .pointer:
            guard let report = PointerReport(body) else { return nil }
            for event in state.applier.apply(report) { record("pointer \(event)") }
            return nil
        case .ping:
            guard let ping = PingBody(body) else { return nil }
            state.sent += 1
            let pong = PingBody(id: ping.id, time: ping.time, hold: 50)
            return try? Datagram.seal(Datagram.Header(kind: .pong, session: sessionID, sequence: state.sent),
                                      body: pong.bytes, key: state.key, direction: .tvToPhone)
        case .pong:
            return nil
        }
    }

    private func broadcast(_ message: [String: Any]) {
        for session in sessions.values { session.send(message) }
    }

    private func record(_ entry: String) {
        log.append(entry)
        var remaining: [(predicate: @Sendable (String) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if waiter.predicate(entry) { waiter.continuation.resume() } else { remaining.append(waiter) }
        }
        waiters = remaining
    }
}

private struct PointerState {
    var key: Data
    var applier = PointerApplier()
    var lastSequence: UInt32 = 0
    var sent: UInt32 = 0
}

/// The TV's end of one connection after the handshake. Its own loop reads; sends come from anywhere.
final class Session: @unchecked Sendable {
    let stream: any ByteStream
    let device: String
    private let sealer: Locked<FrameSealer>
    private var opener: FrameOpener

    init(stream: any ByteStream, session: NoiseSession, device: String) {
        self.stream = stream
        self.device = device
        sealer = Locked(FrameSealer(cipher: session.send))
        opener = FrameOpener(cipher: session.receive)
    }

    func send(_ message: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: message) else { return }
        sealer.withLock { sealer in
            if let frame = try? sealer.seal(json) { stream.send(frame) }
        }
    }

    /// The next frame as a JSON object; throws at the end of the stream.
    func receive() async throws -> [String: Any] {
        while true {
            if let plaintext = try opener.next() {
                guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else { throw StreamError.closed }
                return object
            }
            opener.append(try await stream.receive(maximum: 16 * 1024))
        }
    }

    func close() {
        stream.close()
    }
}

extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start]) | UInt32(self[start + 1]) << 8 | UInt32(self[start + 2]) << 16 | UInt32(self[start + 3]) << 24
    }
}
