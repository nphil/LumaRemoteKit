#if canImport(Network)
import Foundation
import LumaRemoteCore
import Network

/// The fake TV on real sockets: TCP and UDP on one port, as the TV uses them.
public final class FakeTVListener: Sendable {
    public let tv: FakeTV
    public let port: UInt16
    private let tcp: NWListener
    private let udp: NWListener

    /// Listens on loopback, or on every interface with `loopbackOnly` off; `advertise` also announces it
    /// over Bonjour as a TV would.
    public init(tv: FakeTV, port: UInt16 = 0, loopbackOnly: Bool = true, advertise: Bool = false) async throws {
        self.tv = tv
        let tcpParameters = NWParameters.tcp
        if loopbackOnly { tcpParameters.requiredInterfaceType = .loopback }
        tcpParameters.allowLocalEndpointReuse = true
        tcp = try NWListener(using: tcpParameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        if advertise {
            let configuration = await tv.configuration
            tcp.service = NWListener.Service(
                name: configuration.name, type: TVAdvertisement.serviceType, domain: nil,
                txtRecord: NWTXTRecord([
                    "v": "1", "id": configuration.id.description, "name": configuration.name,
                    "mac": configuration.mac.replacingOccurrences(of: ":", with: ""), "pair": configuration.pairingOpen ? "1" : "0",
                ])
            )
        }
        tcp.newConnectionHandler = { connection in
            let stream = TCPStream.accept(connection)
            Task { await tv.serve(stream) }
        }
        self.port = try await Self.ready(tcp)

        let udpParameters = NWParameters.udp
        if loopbackOnly { udpParameters.requiredInterfaceType = .loopback }
        udpParameters.allowLocalEndpointReuse = true
        udp = try NWListener(using: udpParameters, on: NWEndpoint.Port(rawValue: self.port)!)
        udp.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.receive(connection, tv: tv)
        }
        _ = try await Self.ready(udp)
    }

    public func stop() {
        tcp.cancel()
        udp.cancel()
    }

    private static func ready(_ listener: NWListener) async throws -> UInt16 {
        let settled = Locked(false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, Error>? = switch state {
                case .ready: .success(listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error): .failure(error)
                case .cancelled: .failure(StreamError.closed)
                default: nil
                }
                guard let result, settled.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: .global())
        }
    }

    private static func receive(_ connection: NWConnection, tv: FakeTV) {
        connection.receiveMessage { data, _, _, error in
            if let data {
                Task {
                    if let reply = await tv.receiveDatagram(data) {
                        connection.send(content: reply, completion: .idempotent)
                    }
                }
            }
            if error == nil { receive(connection, tv: tv) }
        }
    }
}
#endif
