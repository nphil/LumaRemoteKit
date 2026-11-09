#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A value behind a lock, for state touched from the motion queue, the network queue and the main
/// actor alike.
package final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    package init(_ value: Value) {
        self.value = value
    }

    package func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Where a TV is reached: by address, or by its Bonjour instance, which Network resolves.
public enum TVAddress: Sendable, Hashable, CustomStringConvertible {
    case host(String, port: UInt16)
    /// An instance of `_lumatv-remote._tcp` in `local.`.
    case service(name: String)

    public var description: String {
        switch self {
        case .host(let host, let port): "\(host):\(port)"
        case .service(let name): "\(name) (Bonjour)"
        }
    }
}

public enum StreamError: Error, Equatable {
    /// The other end closed, or the stream was closed here.
    case closed
    case timedOut
    /// The connection could not be made.
    case unreachable(String)
}

/// A reliable, ordered byte stream: TCP to the TV, or an in-memory pipe in tests.
public protocol ByteStream: AnyObject, Sendable {
    /// Queues bytes in call order without waiting; a failure ends the stream and the next receive throws.
    func send(_ bytes: Data)
    /// Between 1 and `maximum` bytes; throws `StreamError.closed` at the end of the stream.
    func receive(maximum: Int) async throws -> Data
    func close()
    /// The other end's address once connected, for the pointer datagrams and Wake-on-LAN.
    var remoteAddress: (host: String, port: UInt16)? { get }
}

extension ByteStream {
    /// Exactly `count` bytes, or a throw if the stream ends first.
    public func receive(exactly count: Int) async throws -> Data {
        var bytes = Data(capacity: count)
        while bytes.count < count {
            bytes.append(try await receive(maximum: count - bytes.count))
        }
        return bytes
    }
}

public enum HandshakeError: Error, Equatable {
    /// The TV took the connection and closed it without answering: it refused the key, or it speaks
    /// another version.
    case refused
    /// The TV's answer did not verify.
    case authenticationFailed
}

/// Runs `operation`, and on a deadline calls `onTimeout`, which must make the operation end (closing its
/// stream does), then throws `StreamError.timedOut`.
public func withDeadline<T: Sendable>(
    _ limit: Duration,
    onTimeout: @escaping @Sendable () -> Void,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let expired = Locked(false)
    let timer = Task {
        try await Task.sleep(for: limit)
        expired.withLock { $0 = true }
        onTimeout()
    }
    defer { timer.cancel() }
    do {
        return try await operation()
    } catch {
        if expired.withLock({ $0 }) { throw StreamError.timedOut }
        throw error
    }
}

/// The phone's end of an open session: a finished handshake and the frames that follow it. Sends may
/// come from any thread; one task reads.
public final class SecureChannel: Sendable {
    public let stream: any ByteStream
    private let sealer: Locked<FrameSealer>
    private let opener: Locked<FrameOpener>
    private let lastSent = Locked(ContinuousClock.now)

    init(stream: any ByteStream, session: NoiseSession) {
        self.stream = stream
        sealer = Locked(FrameSealer(cipher: session.send))
        opener = Locked(FrameOpener(cipher: session.receive))
    }

    /// Sends the preamble and runs the handshake as initiator; `ephemeral` is fixed only by tests.
    public static func open(
        _ stream: any ByteStream,
        mode: Preamble.Mode,
        psk: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) async throws -> SecureChannel {
        let preamble = Preamble.bytes(mode)
        var handshake = NoiseHandshake(role: .initiator, prologue: preamble, psk: psk, ephemeral: ephemeral)
        stream.send(preamble + (try handshake.writeFirst()))
        let reply: Data
        do {
            reply = try await stream.receive(exactly: NoiseHandshake.messageLength)
        } catch StreamError.closed {
            throw HandshakeError.refused
        }
        do {
            return SecureChannel(stream: stream, session: try handshake.readSecond(reply))
        } catch {
            stream.close()
            throw HandshakeError.authenticationFailed
        }
    }

    /// Seals and queues one message; sealing and queueing happen under one lock so the frames reach the
    /// stream in nonce order.
    public func send(_ message: ClientMessage) throws {
        let plaintext = try message.json()
        try sealer.withLock { sealer in
            stream.send(try sealer.seal(plaintext))
        }
        lastSent.withLock { $0 = .now }
    }

    /// The next message from the TV.
    public func receive() async throws -> ServerMessage {
        while true {
            if let plaintext = try opener.withLock({ try $0.next() }) {
                return try ServerMessage(json: plaintext)
            }
            let bytes = try await stream.receive(maximum: 16 * 1024)
            opener.withLock { $0.append(bytes) }
        }
    }

    /// How long since the phone last sent a frame.
    public var idleTime: Duration {
        .now - lastSent.withLock { $0 }
    }

    public func close() {
        stream.close()
    }
}
