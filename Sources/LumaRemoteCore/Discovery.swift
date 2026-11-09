import Foundation

/// What a TV announces over Bonjour as `_lumatv-remote._tcp`.
public struct TVAdvertisement: Sendable, Hashable, Identifiable {
    public static let serviceType = "_lumatv-remote._tcp"
    public static let supportedVersion = 1

    public var id: TVID
    /// The Bonjour instance, which is also the TV's name.
    public var service: String
    public var name: String
    /// The wired MAC for Wake-on-LAN.
    public var mac: String?
    public var version: Int
    /// Whether the TV is showing a pairing code right now.
    public var pairingOpen: Bool

    public init(id: TVID, service: String, name: String, mac: String?, version: Int, pairingOpen: Bool) {
        self.id = id
        self.service = service
        self.name = name
        self.mac = mac
        self.version = version
        self.pairingOpen = pairingOpen
    }

    /// Nil without a valid `id`.
    public init?(service: String, txt: [String: String]) {
        guard let id = txt["id"].flatMap(TVID.init) else { return nil }
        let name = txt["name"].flatMap { $0.isEmpty ? nil : $0 } ?? service
        self.init(
            id: id,
            service: service,
            name: name,
            mac: txt["mac"],
            version: txt["v"].flatMap(Int.init) ?? 0,
            pairingOpen: txt["pair"] == "1"
        )
    }

    /// A TV on another protocol version closes without answering, so the phone checks first.
    public var isSupported: Bool { version == Self.supportedVersion }
}

public enum DiscoveryEvent: Sendable, Equatable {
    /// Every TV seen right now.
    case found([TVAdvertisement])
    /// iOS refused Local Network access.
    case denied
}

/// Wake-on-LAN's magic packet. iOS apps without the multicast entitlement cannot broadcast, so it goes
/// to the TV's last address: whether a TV in deep standby accepts that is untested.
public enum WakeOnLAN {
    public static let port: UInt16 = 9

    /// Six `FF` bytes, then the MAC 16 times; nil when `mac` is not 6 bytes of hex, with or without
    /// separators.
    public static func magicPacket(mac: String) -> Data? {
        let hex = mac.filter { $0 != ":" && $0 != "-" && $0 != "." }
        guard hex.count == 12, let bytes = Data(hexString: hex) else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(bytes) }
        return packet
    }
}

#if canImport(Network)
import Network

extension TVAddress {
    var endpoint: NWEndpoint {
        switch self {
        case .host(let host, let port):
            .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 18733)
        case .service(let name):
            .service(name: name, type: TVAdvertisement.serviceType, domain: "local.", interface: nil)
        }
    }
}

/// Browses for TVs while the stream is consumed.
public enum TVDiscovery {
    public static func browse() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: TVAdvertisement.serviceType, domain: "local."),
                using: NWParameters()
            )
            browser.browseResultsChangedHandler = { results, _ in
                let tvs = results.compactMap { result -> TVAdvertisement? in
                    guard case .service(let name, _, _, _) = result.endpoint,
                          case .bonjour(let txt) = result.metadata
                    else { return nil }
                    return TVAdvertisement(service: name, txt: txt.dictionary)
                }
                continuation.yield(.found(tvs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }))
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    // kDNSServiceErr_PolicyDenied: Local Network access is off for this app.
                    if case .dns(let code) = error, code == -65570 { continuation.yield(.denied) }
                default:
                    break
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .global(qos: .userInitiated))
        }
    }
}

/// TCP to the TV with Nagle off, so a key goes out the moment it is sealed.
public final class TCPStream: ByteStream {
    private let connection: NWConnection

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// A connection a listener accepted, for a TV's side such as the fake TV.
    public static func accept(_ connection: NWConnection) -> TCPStream {
        connection.start(queue: .global(qos: .userInteractive))
        return TCPStream(connection)
    }

    public static func connect(to address: TVAddress, timeout: Duration = .seconds(4)) async throws -> TCPStream {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(timeout.components.seconds))
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // The TV is on the LAN; a cellular path can only fail slowly.
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(to: address.endpoint, using: parameters)
        let stream = TCPStream(connection)
        let settled = Locked(false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                @Sendable func settle(_ result: Result<Void, Error>) {
                    guard settled.withLock({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        settle(.success(()))
                    case .waiting(let error), .failed(let error):
                        // Waiting means unreachable for now: the link's own backoff retries.
                        connection.cancel()
                        settle(.failure(StreamError.unreachable(error.localizedDescription)))
                    case .cancelled:
                        settle(.failure(StreamError.closed))
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInteractive))
            }
        } onCancel: {
            connection.cancel()
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        return stream
    }

    public func send(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { [connection] error in
            if error != nil { connection.cancel() }
        })
    }

    public func receive(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, _ in
                // Data comes before any end-of-stream or error reported with it.
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: StreamError.closed)
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }

    public var remoteAddress: (host: String, port: UInt16)? {
        guard case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint else { return nil }
        return (host.text, port.rawValue)
    }
}

/// The pointer channel's UDP socket, connected to the TV's address and port.
public final class UDPPort: Sendable {
    private let connection: NWConnection

    public init(host: String, port: UInt16, onReceive: @escaping @Sendable (Data) -> Void) {
        let parameters = NWParameters.udp
        parameters.prohibitedInterfaceTypes = [.cellular]
        connection = NWConnection(to: TVAddress.host(host, port: port).endpoint, using: parameters)
        connection.start(queue: .global(qos: .userInteractive))
        Self.receiveLoop(connection, onReceive)
    }

    private static func receiveLoop(_ connection: NWConnection, _ onReceive: @escaping @Sendable (Data) -> Void) {
        connection.receiveMessage { data, _, _, error in
            if let data { onReceive(data) }
            if error == nil { receiveLoop(connection, onReceive) }
        }
    }

    public func send(_ datagram: Data) {
        connection.send(content: datagram, completion: .idempotent)
    }

    public func close() {
        connection.cancel()
    }
}

extension WakeOnLAN {
    /// Sends the magic packet to `host`, port 9, three times 100 ms apart, since UDP may drop one.
    public static func send(mac: String, host: String) async {
        guard let packet = magicPacket(mac: mac) else { return }
        let port = UDPPort(host: host, port: Self.port) { _ in }
        defer { port.close() }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            port.send(packet)
        }
        // Give the last send time to leave before the socket closes.
        try? await Task.sleep(for: .milliseconds(100))
    }
}

extension NWEndpoint.Host {
    var text: String {
        switch self {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        case .name(let name, _): name
        @unknown default: "\(self)"
        }
    }
}
#endif
