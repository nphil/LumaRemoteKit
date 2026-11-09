#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum NoiseError: Error, Equatable {
    /// A tag did not verify: the wrong key, or bytes changed on the way.
    case authenticationFailed
    case malformedMessage
    case nonceExhausted
}

/// One direction of a finished Noise session: ChaCha20-Poly1305 with the nonce counting messages.
public struct CipherState: Sendable {
    private let key: SymmetricKey
    public private(set) var nonce: UInt64 = 0

    init(key: Data) {
        self.key = SymmetricKey(data: key)
    }

    public mutating func encrypt(_ plaintext: Data, associatedData: Data = Data()) throws -> Data {
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        defer { nonce += 1 }
        return try ChaCha.seal(plaintext, key: key, nonce: ChaCha.counterNonce(nonce), associatedData: associatedData)
    }

    public mutating func decrypt(_ ciphertext: Data, associatedData: Data = Data()) throws -> Data {
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        let plaintext = try ChaCha.open(ciphertext, key: key, nonce: ChaCha.counterNonce(nonce), associatedData: associatedData)
        nonce += 1
        return plaintext
    }
}

/// The two ciphers a handshake ends with, named from this side's point of view.
public struct NoiseSession: Sendable {
    public var send: CipherState
    public var receive: CipherState
}

/// `Noise_NNpsk0_25519_ChaChaPoly_SHA256` (Noise revision 34) with empty payloads, the only pattern
/// LumaTV speaks: `-> psk, e` then `<- e, ee`. Both messages are 48 bytes, an ephemeral key and a tag.
/// The responder side exists for the fake TV and the test vectors.
public struct NoiseHandshake {
    public enum Role: Sendable { case initiator, responder }

    public static let messageLength = 48
    static let protocolName = Data("Noise_NNpsk0_25519_ChaChaPoly_SHA256".utf8)

    public let role: Role
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let psk: Data
    private var chainingKey: Data
    private var hash: Data
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?

    /// `ephemeral` is fixed only by tests and vectors; a session always takes a fresh one.
    public init(role: Role, prologue: Data, psk: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.role = role
        self.psk = psk
        self.ephemeral = ephemeral
        // The name is longer than SHA-256's 32 bytes, so it is hashed rather than padded.
        hash = Data(SHA256.hash(data: Self.protocolName))
        chainingKey = hash
        mixHash(prologue)
    }

    /// Initiator: `psk, e` and the tag over the empty payload.
    public mutating func writeFirst() throws -> Data {
        precondition(role == .initiator)
        mixKeyAndHash(psk)
        let message = writeEphemeral()
        return try message + encryptAndHash(Data())
    }

    /// Responder: checks the tag before any Diffie-Hellman, so a wrong key costs one hash.
    public mutating func readFirst(_ message: Data) throws {
        precondition(role == .responder)
        guard message.count == Self.messageLength else { throw NoiseError.malformedMessage }
        mixKeyAndHash(psk)
        try readEphemeral(message.prefix(32))
        _ = try decryptAndHash(message.suffix(16))
    }

    /// Responder: `e, ee` and the tag; the session is open after this.
    public mutating func writeSecond() throws -> (message: Data, session: NoiseSession) {
        precondition(role == .responder)
        let message = writeEphemeral()
        try mixKey(sharedSecret())
        let finished = try message + encryptAndHash(Data())
        let (initiatorToResponder, responderToInitiator) = split()
        return (finished, NoiseSession(send: responderToInitiator, receive: initiatorToResponder))
    }

    /// Initiator: the TV's answer; the session is open after this.
    public mutating func readSecond(_ message: Data) throws -> NoiseSession {
        precondition(role == .initiator)
        guard message.count == Self.messageLength else { throw NoiseError.malformedMessage }
        try readEphemeral(message.prefix(32))
        try mixKey(sharedSecret())
        _ = try decryptAndHash(message.suffix(16))
        let (initiatorToResponder, responderToInitiator) = split()
        return NoiseSession(send: initiatorToResponder, receive: responderToInitiator)
    }

    // MARK: Symmetric state

    private mutating func writeEphemeral() -> Data {
        let publicKey = ephemeral.publicKey.rawRepresentation
        mixHash(publicKey)
        // PSK patterns also mix every ephemeral key into the chaining key.
        mixKey(publicKey)
        return publicKey
    }

    private mutating func readEphemeral(_ bytes: Data) throws {
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes) else {
            throw NoiseError.malformedMessage
        }
        remoteEphemeral = publicKey
        mixHash(bytes)
        mixKey(bytes)
    }

    private func sharedSecret() throws -> Data {
        guard let remoteEphemeral else { throw NoiseError.malformedMessage }
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: remoteEphemeral)
        return secret.withUnsafeBytes { Data($0) }
    }

    private mutating func mixHash(_ data: Data) {
        hash = Data(SHA256.hash(data: hash + data))
    }

    private mutating func mixKey(_ material: Data) {
        let outputs = Self.hkdf(chainingKey: chainingKey, material: material, count: 2)
        chainingKey = outputs[0]
        setKey(outputs[1])
    }

    private mutating func mixKeyAndHash(_ material: Data) {
        let outputs = Self.hkdf(chainingKey: chainingKey, material: material, count: 3)
        chainingKey = outputs[0]
        mixHash(outputs[1])
        setKey(outputs[2])
    }

    private mutating func setKey(_ bytes: Data) {
        key = SymmetricKey(data: bytes)
        nonce = 0
    }

    private mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let key else { throw NoiseError.malformedMessage }
        let ciphertext = try ChaCha.seal(plaintext, key: key, nonce: ChaCha.counterNonce(nonce), associatedData: hash)
        nonce += 1
        mixHash(ciphertext)
        return ciphertext
    }

    private mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let key else { throw NoiseError.malformedMessage }
        let plaintext = try ChaCha.open(ciphertext, key: key, nonce: ChaCha.counterNonce(nonce), associatedData: hash)
        nonce += 1
        mixHash(ciphertext)
        return plaintext
    }

    private func split() -> (CipherState, CipherState) {
        let outputs = Self.hkdf(chainingKey: chainingKey, material: Data(), count: 2)
        return (CipherState(key: outputs[0]), CipherState(key: outputs[1]))
    }

    /// Noise's HKDF: HMAC-SHA-256 extract, then two or three chained expand blocks.
    static func hkdf(chainingKey: Data, material: Data, count: Int) -> [Data] {
        let tempKey = hmac(key: chainingKey, data: material)
        var outputs: [Data] = []
        var previous = Data()
        for index in 1...count {
            previous = hmac(key: tempKey, data: previous + [UInt8(index)])
            outputs.append(previous)
        }
        return outputs
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

/// ChaCha20-Poly1305 with the ciphertext and its 16-byte tag kept together, as both the frames and the
/// datagrams carry them.
enum ChaCha {
    static let tagLength = 16

    /// Noise's nonce: four zero bytes, then the counter little-endian.
    static func counterNonce(_ counter: UInt64) -> Data {
        var nonce = Data(count: 4)
        nonce.appendLittleEndian(counter)
        return nonce
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: Data, associatedData: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: associatedData)
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: SymmetricKey, nonce: Data, associatedData: Data) throws -> Data {
        guard sealed.count >= tagLength else { throw NoiseError.malformedMessage }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonce),
                ciphertext: sealed.prefix(sealed.count - tagLength),
                tag: sealed.suffix(tagLength)
            )
            return try ChaChaPoly.open(box, using: key, authenticating: associatedData)
        } catch {
            throw NoiseError.authenticationFailed
        }
    }
}
