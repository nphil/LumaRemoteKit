import Foundation

public enum FrameError: Error, Equatable {
    /// A length outside 16…8,208 bytes: no tag, or more than the 8,192-byte plaintext limit.
    case badLength(Int)
    /// A plaintext over 8,192 bytes.
    case tooLong(Int)
}

/// Seals plaintexts into frames: a u16 length, then the ciphertext and its 16-byte tag.
public struct FrameSealer: Sendable {
    public static let maxPlaintext = 8192

    private var cipher: CipherState

    public init(cipher: CipherState) {
        self.cipher = cipher
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= Self.maxPlaintext else { throw FrameError.tooLong(plaintext.count) }
        let ciphertext = try cipher.encrypt(plaintext)
        var frame = Data(capacity: 2 + ciphertext.count)
        frame.appendLittleEndian(UInt16(ciphertext.count))
        frame.append(ciphertext)
        return frame
    }
}

/// Collects stream bytes and opens each complete frame in order.
public struct FrameOpener: Sendable {
    private var cipher: CipherState
    private var buffer = Data()

    public init(cipher: CipherState) {
        self.cipher = cipher
    }

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// The next frame's plaintext, or nil until all of it has arrived.
    public mutating func next() throws -> Data? {
        guard buffer.count >= 2 else { return nil }
        let length = Int(buffer.littleEndian(UInt16.self, at: 0))
        guard length >= ChaCha.tagLength, length <= FrameSealer.maxPlaintext + ChaCha.tagLength else {
            throw FrameError.badLength(length)
        }
        guard buffer.count >= 2 + length else { return nil }
        let start = buffer.startIndex + 2
        let plaintext = try cipher.decrypt(buffer.subdata(in: start..<(start + length)))
        buffer.removeSubrange(buffer.startIndex..<(start + length))
        return plaintext
    }
}

/// The 6 bytes a connection opens with, which are also the handshake's prologue.
public enum Preamble {
    public enum Mode: UInt8, Sendable {
        case session = 1
        case pairing = 2
    }

    public static let version: UInt8 = 1

    public static func bytes(_ mode: Mode) -> Data {
        Data([0x4C, 0x52, 0x4D, 0x54, version, mode.rawValue])
    }
}
