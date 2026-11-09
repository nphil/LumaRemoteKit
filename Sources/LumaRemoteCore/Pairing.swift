#if canImport(CommonCrypto)
import CommonCrypto
#elseif canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A TV's id: 8 random bytes the TV made when its phone-remote plugin was first switched on, written as
/// 16 lowercase hex digits.
public struct TVID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: Data

    public init?(_ hex: String) {
        guard hex.utf8.count == 16, let bytes = Data(hexString: hex) else { return nil }
        self.bytes = bytes
    }

    public var description: String { bytes.hexString }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let id = TVID(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A TV id is 16 hex digits")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The 8-character code the TV shows while pairing is open, from the alphabet 2–9 and A–Z without I and O.
public struct PairingCode: Hashable, Sendable, CustomStringConvertible {
    public static let alphabet = Set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    public static let length = 8

    /// Upper case, without the dash.
    public let characters: String

    /// A typed code: upper-cased with spaces and dashes removed. Nil when it is not 8 characters of the
    /// alphabet, so a typo is refused before connecting.
    public init?(_ typed: String) {
        let cleaned = typed.uppercased().filter { $0 != " " && $0 != "-" }
        guard cleaned.count == Self.length, cleaned.allSatisfy(Self.alphabet.contains) else { return nil }
        characters = cleaned
    }

    /// As the TV shows it, `XXXX-XXXX`.
    public var description: String {
        "\(characters.prefix(4))-\(characters.suffix(4))"
    }
}

/// The pre-shared key for a pairing connection: PBKDF2-HMAC-SHA256 of the code, salted with
/// `LumaRemote pair v1` and the TV's id, 131,072 iterations, 32 bytes. About a tenth of a second on a
/// phone, so it runs off the main thread.
public enum PairingKey {
    public static let iterations = 131_072
    static let saltPrefix = Data("LumaRemote pair v1".utf8)

    public static func derive(code: PairingCode, tv: TVID) -> Data {
        pbkdf2(password: Data(code.characters.utf8), salt: saltPrefix + tv.bytes, iterations: iterations)
    }

    static func pbkdf2(password: Data, salt: Data, iterations: Int) -> Data {
        #if canImport(CommonCrypto)
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 32
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed with \(status)")
        return key
        #else
        // One SHA-256-sized block is all a 32-byte key needs.
        let hmacKey = SymmetricKey(data: password)
        var block = Data(HMAC<SHA256>.authenticationCode(for: salt + [0, 0, 0, 1], using: hmacKey))
        var key = [UInt8](block)
        for _ in 1..<iterations {
            block = Data(HMAC<SHA256>.authenticationCode(for: block, using: hmacKey))
            for (index, byte) in block.enumerated() { key[index] ^= byte }
        }
        return Data(key)
        #endif
    }
}

/// What the phone tells the TV about itself, shown in the TV's list of paired phones.
public struct PhoneInfo: Sendable, Hashable, Codable {
    public static let nameLimit = 40

    /// 1–40 characters; iOS reports only the model's name, so the person types it.
    public var name: String
    /// The hardware identifier, such as `iPhone17,1`.
    public var model: String
    /// The host app and its version, such as `Marquee 0.1.21`.
    public var app: String

    public init(name: String, model: String, app: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = String((trimmed.isEmpty ? "iPhone" : trimmed).prefix(Self.nameLimit))
        self.model = model
        self.app = app
    }

    /// The hardware identifier of the device this runs on; the simulator reports the one it imitates.
    public static var hardwareModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// A TV this phone is paired with: what the TV sent once inside the encrypted pairing session, plus
/// where it was last reached.
public struct PairedTV: Sendable, Hashable, Codable, Identifiable {
    public var id: TVID
    public var name: String
    /// The wired MAC as `aa:bb:cc:dd:ee:ff`, for Wake-on-LAN.
    public var mac: String
    /// The id the TV gave this phone.
    public var device: String
    /// The phone's 32-byte session key.
    public var key: Data
    /// The address it was last reached at, also where a wake packet goes.
    public var host: String
    public var port: UInt16
    /// The TV's Bonjour instance when pairing found it that way; tried when `host` fails.
    public var service: String?
    public var pairedAt: Date

    public init(
        id: TVID, name: String, mac: String, device: String, key: Data,
        host: String, port: UInt16, service: String? = nil, pairedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.mac = mac
        self.device = device
        self.key = key
        self.host = host
        self.port = port
        self.service = service
        self.pairedAt = pairedAt
    }
}

/// The `lumaremote://pair?h=…&p=…&id=…&c=…` link the TV's QR code carries.
public struct PairingInvite: Sendable, Hashable {
    public static let scheme = "lumaremote"
    public static let defaultPort: UInt16 = 18733

    public var host: String
    public var port: UInt16
    public var tv: TVID
    public var code: PairingCode

    public init(host: String, port: UInt16 = PairingInvite.defaultPort, tv: TVID, code: PairingCode) {
        self.host = host
        self.port = port
        self.tv = tv
        self.code = code
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let host = value("h"), !host.isEmpty,
              let tv = value("id").flatMap(TVID.init),
              let code = value("c").flatMap(PairingCode.init)
        else { return nil }
        var port = Self.defaultPort
        if let text = value("p") {
            guard let parsed = UInt16(text) else { return nil }
            port = parsed
        }
        self.init(host: host, port: port, tv: tv, code: code)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "h", value: host),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "id", value: tv.description),
            URLQueryItem(name: "c", value: code.characters),
        ]
        return components.url!
    }
}
