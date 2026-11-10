import Foundation
@testable import LumaRemoteCore
import LumaRemoteFakeTV
#if canImport(Network)
import Network
#endif
import Testing

private let phone = PhoneInfo(name: "Test iPhone", model: "iPhone17,1", app: "Tests")

private final class PathStream: ByteStream {
    let stream: any ByteStream
    let connectionPath: ConnectionPath?
    init(_ stream: any ByteStream, path: ConnectionPath) {
        self.stream = stream
        connectionPath = path
    }
    var remoteAddress: (host: String, port: UInt16)? { stream.remoteAddress }
    func send(_ bytes: Data) { stream.send(bytes) }
    func receive(maximum: Int) async throws -> Data { try await stream.receive(maximum: maximum) }
    func close() { stream.close() }
}

@Test func onlyAnAuthenticatedLiveSessionExposesItsPath() async throws {
    let tv = FakeTV()
    let pairedTV = try await paired(with: tv)
    let expected = ConnectionPath(localAddress: "192.168.1.10", remoteAddress: "192.168.1.20", usesWiFi: true, usesOther: false)
    let connector = PipeStream.connector(to: tv)
    let link = TVLink(tv: pairedTV, phone: phone, connect: { address in
        PathStream(try await connector(address), path: expected)
    })
    #expect(link.connectionPath == nil)
    _ = try #require(await connected(link))
    #expect(link.connectionPath == expected)
    await link.stop()
    #expect(link.connectionPath == nil)
}

private func paired(with tv: FakeTV) async throws -> PairedTV {
    let configuration = await tv.configuration
    return try await Pairing.pair(address: .host("127.0.0.1", port: 18733), tv: configuration.id, code: configuration.code,
                                  phone: phone, connect: PipeStream.connector(to: tv))
}

/// The link's first welcome, after which the session is open.
private func connected(_ link: TVLink) async -> Welcome? {
    await link.start()
    for await event in link.events {
        if case .welcome(let welcome) = event { return welcome }
        if case .status(let status) = event, status == .rejected || status == .revoked { return nil }
    }
    return nil
}

@Test func pairingGivesAKeyTheTVAccepts() async throws {
    let tv = FakeTV()
    let pairedTV = try await paired(with: tv)
    #expect(pairedTV.name == "Living Room TV")
    #expect(await tv.phones[pairedTV.device] == pairedTV.key)

    let link = TVLink(tv: pairedTV, phone: phone, connect: PipeStream.connector(to: tv))
    let welcome = try #require(await connected(link))
    #expect(welcome.tv.accent == "#c8a2ff" && welcome.udp.key.count == 32)
    #expect(link.send(.key(.volumeUp, .tap)))
    await tv.waitFor { $0 == "key volup tap" }
    await link.stop()
}

@Test func wrongCodeIsRefused() async throws {
    var configuration = FakeTV.Configuration()
    let tv = FakeTV(configuration)
    configuration.code = PairingCode("WRNG2345")!
    await #expect(throws: PairingError.wrongCode) {
        try await Pairing.pair(address: .host("127.0.0.1", port: 18733), tv: configuration.id, code: configuration.code,
                               phone: phone, connect: PipeStream.connector(to: tv))
    }
}

#if canImport(Network)
@Test func abortClosesPendingReceive() async throws {
    let listener = try await FakeTVListener(tv: FakeTV())
    defer { listener.stop() }
    let stream = try await TCPStream.connect(to: .host("127.0.0.1", port: listener.port))
    stream.abort()
    await #expect(throws: (any Error).self) {
        try await stream.receive(maximum: 1)
    }
}

/// A read on a stream closed here throws `closed` without touching the connection.
@Test func readingAClosedStreamThrowsClosed() async throws {
    let listener = try await FakeTVListener(tv: FakeTV())
    defer { listener.stop() }
    let stream = try await TCPStream.connect(to: .host("127.0.0.1", port: listener.port))
    stream.close()
    await #expect(throws: StreamError.closed) { try await stream.receive(maximum: 1) }
}

/// Resolves once `state` settles: `.ready`, or a throw for `.waiting`, `.failed` and `.cancelled`.
private func ready(_ state: NWListener.State) -> Result<Void, Error>? {
    switch state {
    case .ready: return .success(())
    case .waiting(let error), .failed(let error): return .failure(error)
    case .cancelled: return .failure(StreamError.closed)
    default: return nil
    }
}

private func ready(_ state: NWConnection.State) -> Result<Void, Error>? {
    switch state {
    case .ready: return .success(())
    case .waiting(let error), .failed(let error): return .failure(error)
    case .cancelled: return .failure(StreamError.closed)
    default: return nil
    }
}

/// A TV's last reply before it hangs up reaches the phone, and the TV's connection is released only
/// once the phone has hung up too, not as soon as the FIN is queued.
@Test func aClosedConnectionStaysUntilThePeerHangsUp() async throws {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    let listener = try NWListener(using: parameters, on: .any)
    defer { listener.cancel() }
    let arrivals = Locked<CheckedContinuation<NWConnection, Never>?>(nil)
    listener.newConnectionHandler = { connection in
        let waiting = arrivals.withLock { continuation in defer { continuation = nil }; return continuation }
        waiting?.resume(returning: connection)
    }
    let listening = Locked(false)
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { state in
            guard let result = ready(state), listening.withLock({ done in defer { done = true }; return !done }) else { return }
            continuation.resume(with: result.map { _ in listener.port?.rawValue ?? 0 })
        }
        listener.start(queue: .global())
    }

    // The phone connects only once the arrival is awaited, so the accepted connection cannot slip by.
    let connecting = Locked<Task<TCPStream, Error>?>(nil)
    let accepted: NWConnection = await withCheckedContinuation { continuation in
        arrivals.withLock { $0 = continuation }
        connecting.withLock { $0 = Task { try await TCPStream.connect(to: .host("127.0.0.1", port: port)) } }
    }
    // TCPStream.accept starts the TV's end; before it is ready, close() can only cancel, which is not the
    // hang-up under test, so the reply goes out once the connection is ready.
    let accepting = Locked(false)
    let server = Locked<TCPStream?>(nil)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        accepted.stateUpdateHandler = { state in
            guard let result = ready(state), accepting.withLock({ done in defer { done = true }; return !done }) else { return }
            continuation.resume(with: result)
        }
        server.withLock { $0 = TCPStream.accept(accepted) }
    }
    let tv = try #require(server.withLock { $0 })
    tv.send(Data("paired".utf8))
    tv.close()

    let phone = try await #require(connecting.withLock { $0 }).value
    let reply = try await phone.receive(exactly: 6)
    #expect(reply == Data("paired".utf8))
    await #expect(throws: StreamError.closed) { try await phone.receive(maximum: 1) }
    var stillUp = false
    if case .ready = accepted.state { stillUp = true }
    #expect(stillUp, "The TV's side hung up before the phone did")

    phone.close()
    let released = Locked(false)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        @Sendable func finish() {
            if released.withLock({ done in defer { done = true }; return !done }) { continuation.resume() }
        }
        accepted.stateUpdateHandler = { if case .cancelled = $0 { finish() } }
        if case .cancelled = accepted.state { finish() }
    }
}

/// On real sockets the TV hangs up right after its reply, which must still arrive.
@Test func pairingOverLoopback() async throws {
    let tv = FakeTV()
    let listener = try await FakeTVListener(tv: tv)
    defer { listener.stop() }
    let configuration = await tv.configuration
    let pairedTV = try await Pairing.pair(address: .host("127.0.0.1", port: listener.port), tv: configuration.id,
                                          code: configuration.code, phone: phone, connect: { try await TCPStream.connect(to: $0) })
    #expect(await tv.phones[pairedTV.device] == pairedTV.key)
}
#endif

@Test func actionsListsAndRevocation() async throws {
    let key = Data(repeating: 9, count: 32)
    var configuration = FakeTV.Configuration()
    configuration.actions = ["guide"]
    let tv = FakeTV(configuration, phones: ["0102030405060708": key])
    let pairedTV = PairedTV(id: configuration.id, name: "TV", mac: configuration.mac, device: "0102030405060708", key: key,
                            host: "127.0.0.1", port: 18733)
    let link = TVLink(tv: pairedTV, phone: phone, connect: PipeStream.connector(to: tv))
    let welcome = try #require(await connected(link))

    try await link.perform(.guide)
    await #expect(throws: TVLink.RequestError.failed("off")) { try await link.perform(.power(on: false)) }
    let channels = try await link.list(.channels)
    #expect(channels.map(\.label) == ["BBC One", "BBC Two"])

    // The pointer channel: totals in, events out; a ping gets its pong.
    var sealer = DatagramSealer(grant: welcome.udp)
    var report = PointerReport()
    report.x = 32
    report.leftPresses = 1
    #expect(await tv.receiveDatagram(try sealer.pointer(report)) == nil)
    #expect(await tv.log.suffix(2) == ["pointer move 32 0", "pointer click left"])
    let pong = try #require(await tv.receiveDatagram(try sealer.ping(id: 3, time: 99)))
    #expect(sealer.pong(pong) == PingBody(id: 3, time: 99, hold: 50))
    #expect(sealer.pong(pong) == nil)

    await tv.revoke(device: "0102030405060708")
    for await event in link.events {
        if case .status(.revoked) = event { break }
    }
    #expect(!link.isConnected)
}

@Test func sessionWithUnknownKeyIsRefused() async throws {
    let key = Data(repeating: 3, count: 32)
    let tv = FakeTV(phones: ["aa": key])
    let configuration = await tv.configuration
    let wrongKey = PairedTV(id: configuration.id, name: "TV", mac: "", device: "bb", key: Data(repeating: 4, count: 32),
                            host: "127.0.0.1", port: 18733)
    let stream = try await PipeStream.connector(to: tv)(.host("127.0.0.1", port: 18733))
    await #expect(throws: HandshakeError.refused) {
        _ = try await SecureChannel.open(stream, mode: .session, psk: wrongKey.key)
    }
}

@Test func backoffDoublesToEightSeconds() {
    #expect(TVLink.backoff(after: 1) == .milliseconds(250))
    #expect(TVLink.backoff(after: 3) == .seconds(1))
    #expect(TVLink.backoff(after: 9) == .seconds(8))
}

@Test(.timeLimit(.minutes(1)))
func aMalformedMemberDoesNotEndTheSession() async throws {
    let tv = FakeTV()
    await tv.setWire(volume: ["via": "receiver", "level": 50.5, "max": 72.5, "muted": false], ime: ["active": "yes"])
    let link = TVLink(tv: try await paired(with: tv), phone: phone, connect: PipeStream.connector(to: tv))
    let welcome = try #require(await connected(link))
    #expect(welcome.state.volume?.level == 50.5 && welcome.state.ime == nil)
    #expect(link.send(.key(.ok, .tap)))
    await tv.waitFor { $0 == "key ok tap" }
    await link.stop()
}

@Test(.timeLimit(.minutes(1)))
func anUndecodableWelcomeReportsIncompatible() async throws {
    var configuration = FakeTV.Configuration()
    configuration.undecodableWelcome = true
    let tv = FakeTV(configuration)
    let link = TVLink(tv: try await paired(with: tv), phone: phone, connect: PipeStream.connector(to: tv))
    await link.start()
    var detail: String?
    for await event in link.events {
        if case .status(.incompatible(let found)) = event { detail = found; break }
    }
    #expect(detail?.contains("tv") == true)
    await link.stop()
}
