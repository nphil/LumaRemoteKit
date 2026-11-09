import Foundation
import LumaRemoteCore

/// One end of an in-memory connection, for tests that run the protocol without sockets.
public final class PipeStream: ByteStream {
    private let incoming: Buffer
    private let outgoing: Buffer

    private init(incoming: Buffer, outgoing: Buffer) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    /// Two connected ends.
    public static func pair() -> (PipeStream, PipeStream) {
        let forward = Buffer()
        let backward = Buffer()
        return (PipeStream(incoming: backward, outgoing: forward), PipeStream(incoming: forward, outgoing: backward))
    }

    /// A connector whose every connection is served by `tv`.
    public static func connector(to tv: FakeTV) -> Connector {
        { _ in
            let (phone, television) = PipeStream.pair()
            Task { await tv.serve(television) }
            return phone
        }
    }

    public func send(_ bytes: Data) {
        outgoing.write(bytes)
    }

    public func receive(maximum: Int) async throws -> Data {
        try await incoming.read(maximum: maximum)
    }

    public func close() {
        incoming.close()
        outgoing.close()
    }

    public var remoteAddress: (host: String, port: UInt16)? { ("127.0.0.1", PairingInvite.defaultPort) }

    private final class Buffer: Sendable {
        private struct State {
            var bytes = Data()
            var closed = false
            var reader: (maximum: Int, continuation: CheckedContinuation<Data, Error>)?
        }

        private let state = Locked(State())

        func write(_ bytes: Data) {
            guard !bytes.isEmpty else { return }
            let resume: (CheckedContinuation<Data, Error>, Data)? = state.withLock { state in
                guard !state.closed else { return nil }
                state.bytes.append(bytes)
                guard let reader = state.reader else { return nil }
                state.reader = nil
                let chunk = state.bytes.prefix(reader.maximum)
                state.bytes.removeFirst(chunk.count)
                return (reader.continuation, Data(chunk))
            }
            if let (continuation, chunk) = resume { continuation.resume(returning: chunk) }
        }

        func read(maximum: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Data, Error>? = state.withLock { state in
                    if !state.bytes.isEmpty {
                        let chunk = state.bytes.prefix(maximum)
                        state.bytes.removeFirst(chunk.count)
                        return .success(Data(chunk))
                    }
                    if state.closed { return .failure(StreamError.closed) }
                    state.reader = (maximum, continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        }

        func close() {
            let reader = state.withLock { state in
                state.closed = true
                defer { state.reader = nil }
                return state.reader?.continuation
            }
            reader?.resume(throwing: StreamError.closed)
        }
    }
}
