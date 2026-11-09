import Foundation
@testable import LumaRemoteCore
import LumaRemoteFakeTV
import Testing

private let phone = PhoneInfo(name: "Test iPhone", model: "iPhone17,1", app: "Tests")

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
