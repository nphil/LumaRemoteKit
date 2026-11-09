import Foundation
import LumaRemoteCore
import LumaRemoteFakeTV
@testable import LumaRemoteKit
import Observation
import Testing

/// The pointer channel to the fake TV: each datagram, and the reply, passed on in order.
private final class FakeSocket: DatagramSocket {
    private let tv: FakeTV
    private let receive: @Sendable (Data) -> Void
    private let last = Locked<Task<Void, Never>?>(nil)

    init(tv: FakeTV, receive: @escaping @Sendable (Data) -> Void) {
        self.tv = tv
        self.receive = receive
    }

    func send(_ datagram: Data) {
        let tv = tv
        let receive = receive
        last.withLock { last in
            let previous = last
            last = Task {
                await previous?.value
                if let reply = await tv.receiveDatagram(datagram) { receive(reply) }
            }
        }
    }

    func close() {}
}

/// A remote served by `tv`, with its settings in a throwaway defaults suite.
@MainActor
private func withRemote(for tv: FakeTV, paired: [PairedTV] = [], _ body: (RemoteModel) async throws -> Void) async rethrows {
    let suite = "LumaRemoteKitTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let services = RemoteModel.Services(
        store: MemoryPairingStore(paired),
        connect: PipeStream.connector(to: tv),
        browse: { AsyncStream { _ in } },
        datagrams: { _, _, receive in FakeSocket(tv: tv, receive: receive) },
        wake: { _, _ in }
    )
    let remote = RemoteModel(app: "Tests 1.0", services: services, settings: RemoteSettings(defaults: defaults))
    remote.activate()
    defer { remote.deactivate() }
    try await body(remote)
}

/// Waits until `condition` holds, checking again whenever something it read changes.
@MainActor
private func until(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func pairsByLinkThenDrivesTheTV() async throws {
    let tv = FakeTV()
    try await withRemote(for: tv) { remote in
        #expect(remote.connection == .none)
        #expect(!remote.open(URL(string: "https://example.com/pair")!))
        #expect(remote.open(await tv.pairingLink(host: "127.0.0.1", port: 18733)))
        let invite = try #require(remote.invite)

        try await remote.pair(invite, phoneName: " Kitchen iPhone ")
        #expect(remote.invite == nil && remote.tvs.map(\.name) == ["Living Room TV"])
        await until { remote.connection == .connected }
        await tv.waitFor { $0 == "hello Kitchen iPhone" }
        #expect(remote.tvAccent == "#c8a2ff" && remote.state.allows(.guide))

        remote.tap(.volumeUp)
        await tv.waitFor { $0 == "key volup tap" }
        await tv.setTextField(active: true)
        await until { remote.state.ime.active }
        remote.type(from: "", to: "hi")
        await tv.waitFor { $0 == "text hi" }
        remote.pointer.move(dx: 2, dy: 0)
        await tv.waitFor { $0 == "pointer move 32 0" }

        let latency = await remote.measureLatency(samples: 2)
        #expect(latency.session?.count == 2 && latency.datagram?.count == 2)
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func refusalsShowAndRevocationUnpairs() async throws {
    var configuration = FakeTV.Configuration()
    configuration.actions = ["guide"]
    let key = Data(repeating: 9, count: 32)
    let device = "0102030405060708"
    let tv = FakeTV(configuration, phones: [device: key])
    let paired = PairedTV(id: configuration.id, name: "TV", mac: configuration.mac, device: device, key: key,
                          host: "127.0.0.1", port: 18733)
    await withRemote(for: tv, paired: [paired]) { remote in
        await until { remote.connection == .connected }
        #expect(remote.current?.name == "Living Room TV")
        #expect(await remote.perform(.guide))
        #expect(await remote.perform(.power(on: false)) == false)
        #expect(remote.notice?.text == "That needs a LumaTV plugin that's switched off.")

        await tv.revoke(device: device)
        await until { remote.connection == .unpaired }
        #expect(!remote.send(.key(.ok, .tap)))
        #expect(remote.notice?.text == "Pair with the TV again to use it.")
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func phoneVolumeButtonsStepTheReceiverByHalves() async throws {
    let key = Data(repeating: 9, count: 32)
    let device = "0102030405060708"
    let configuration = FakeTV.Configuration()
    let tv = FakeTV(configuration, phones: [device: key])
    await tv.setWire(volume: ["via": "receiver", "level": 50, "max": 72.5, "muted": false])
    let paired = PairedTV(id: configuration.id, name: "TV", mac: configuration.mac, device: device, key: key,
                          host: "127.0.0.1", port: 18733)
    await withRemote(for: tv, paired: [paired]) { remote in
        await until { remote.connection == .connected && remote.state.volume?.level == 50 }
        remote.volumeButton(.volumeUp)
        await tv.waitFor { $0 == "act volume level=50.5" }
        remote.volumeButton(.volumeDown)
        remote.volumeButton(.volumeDown)
        await tv.waitFor { $0 == "act volume level=49.5" }
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func undecodableWelcomeShowsIncompatibleWithTheError() async throws {
    var configuration = FakeTV.Configuration()
    configuration.undecodableWelcome = true
    let key = Data(repeating: 9, count: 32)
    let device = "0102030405060708"
    let tv = FakeTV(configuration, phones: [device: key])
    let paired = PairedTV(id: configuration.id, name: "TV", mac: configuration.mac, device: device, key: key,
                          host: "127.0.0.1", port: 18733)
    await withRemote(for: tv, paired: [paired]) { remote in
        await until { remote.connection == .incompatible }
        #expect(remote.statusText == "The TV answered in a way this app doesn't understand. Update Marquee or LumaTV.")
        #expect(remote.incompatibility?.contains("tv") == true)
    }
}
