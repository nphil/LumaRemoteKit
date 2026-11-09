#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
@testable import LumaRemoteCore
import Testing

/// LumaTV's `helper/remote/tests/vectors.json`, copied verbatim; CI fails when the two differ.
struct Vectors: Decodable {
    struct Pairing: Decodable { var typed, code, display, tv, key: String }
    struct Frame: Decodable { var from, json, frame: String }
    struct Handshake: Decodable {
        var mode, preamble, psk, phoneEphemeral, tvEphemeral, message1, message2: String
        var frames: [Frame]
    }
    struct Datagrams: Decodable {
        struct Item: Decodable {
            var kind, direction: UInt8
            var seq: UInt32
            var header, nonce, plain, packet: String
        }
        var key: String
        var session: UInt32
        var items: [Item]
    }
    struct Totals: Decodable {
        var x, y, scrollX, scrollY: Int32
        var buttons, left, right, centre, flags: UInt8

        var report: PointerReport {
            var report = PointerReport()
            report.x = x
            report.y = y
            report.scrollX = scrollX
            report.scrollY = scrollY
            report.held = .init(rawValue: buttons)
            report.leftPresses = left
            report.rightPresses = right
            report.centres = centre
            report.flags = .init(rawValue: flags)
            return report
        }
    }
    struct Event: Decodable {
        var event: PointerEvent

        private enum CodingKeys: String, CodingKey { case e, on, dx, dy, button }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func button() throws -> PointerButton {
                switch try container.decode(String.self, forKey: .button) {
                case "left": return .left
                case "right": return .right
                default: throw DecodingError.dataCorruptedError(forKey: .button, in: container, debugDescription: "unknown button")
                }
            }
            func delta() throws -> (dx: Int32, dy: Int32) {
                (try container.decode(Int32.self, forKey: .dx), try container.decode(Int32.self, forKey: .dy))
            }
            switch try container.decode(String.self, forKey: .e) {
            case "engaged": event = .engaged(try container.decode(Bool.self, forKey: .on))
            case "centre": event = .centre
            case "move": event = try .move(dx: delta().dx, dy: delta().dy)
            case "scroll": event = try .scroll(dx: delta().dx, dy: delta().dy)
            case "click": event = .click(try button())
            case "press": event = .press(try button())
            case "release": event = .release(try button())
            default: throw DecodingError.dataCorruptedError(forKey: .e, in: container, debugDescription: "unknown event")
            }
        }
    }
    struct Step: Decodable {
        var totals: Totals
        var plain: String
        /// Never arrives; the next step carries what it held.
        var lost: Bool?
        var events: [Event]?
    }
    struct Sequence: Decodable {
        var name: String
        var start: Totals
        var steps: [Step]
    }

    var version: Int
    var pairing: [Pairing]
    var refused: [String]
    var handshakes: [Handshake]
    var datagrams: Datagrams
    var pointer: [Sequence]

    static let shared: Vectors = {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json")!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Vectors.self, from: Data(contentsOf: url))
    }()
}

extension Data {
    init(hex: String) {
        self = Data(hexString: hex)!
    }
}

@Test func protocolVersion() {
    #expect(Vectors.shared.version == Int(Preamble.version))
}

@Test func pairingCodesAndKeys() throws {
    for vector in Vectors.shared.pairing {
        let code = try #require(PairingCode(vector.typed))
        #expect(code.characters == vector.code)
        #expect(code.description == vector.display)
        #expect(PairingKey.derive(code: code, tv: try #require(TVID(vector.tv))).hexString == vector.key)
    }
}

@Test func refusedCodes() {
    for typed in Vectors.shared.refused {
        #expect(PairingCode(typed) == nil, "\(typed)")
    }
}

/// The message the kit sends for a phone frame of the vectors, built from that frame's fields.
private func kitMessage(for json: String) throws -> ClientMessage {
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    func field(_ name: String) throws -> String { try #require(object[name] as? String) }
    func phone() throws -> PhoneInfo { PhoneInfo(name: try field("name"), model: try field("model"), app: try field("app")) }
    switch try field("t") {
    case "hello": return .hello(try phone(), kit: try field("kit"))
    case "pair": return .pair(try phone())
    case "key": return .key(try #require(RemoteKey(rawValue: try field("k"))), try #require(KeyAction(rawValue: try field("a"))))
    case let other: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no phone message \(other)"))
    }
}

private func sameJSON(_ left: Data, _ right: Data) throws -> Bool {
    let left = try JSONSerialization.jsonObject(with: left) as? NSDictionary
    let right = try JSONSerialization.jsonObject(with: right) as? NSDictionary
    return left != nil && left == right
}

@Test(arguments: Vectors.shared.handshakes.map(\.mode))
func handshake(mode: String) throws {
    let vector = Vectors.shared.handshakes.first { $0.mode == mode }!
    let preamble = Data(hex: vector.preamble)
    #expect(preamble == Preamble.bytes(mode == "session" ? .session : .pairing))
    let psk = Data(hex: vector.psk)
    var phone = NoiseHandshake(role: .initiator, prologue: preamble, psk: psk,
                               ephemeral: try .init(rawRepresentation: Data(hex: vector.phoneEphemeral)))
    var tv = NoiseHandshake(role: .responder, prologue: preamble, psk: psk,
                            ephemeral: try .init(rawRepresentation: Data(hex: vector.tvEphemeral)))

    let first = try phone.writeFirst()
    #expect(first.hexString == vector.message1)
    try tv.readFirst(first)
    let (second, tvSession) = try tv.writeSecond()
    #expect(second.hexString == vector.message2)
    let phoneSession = try phone.readSecond(second)

    var phoneSealer = FrameSealer(cipher: phoneSession.send)
    var phoneOpener = FrameOpener(cipher: phoneSession.receive)
    var tvSealer = FrameSealer(cipher: tvSession.send)
    var tvOpener = FrameOpener(cipher: tvSession.receive)
    for frame in vector.frames {
        let plaintext = Data(frame.json.utf8)
        if frame.from == "phone" {
            #expect(try sameJSON(try kitMessage(for: frame.json).json(), plaintext), "\(frame.json)")
            #expect(try phoneSealer.seal(plaintext).hexString == frame.frame)
            tvOpener.append(Data(hex: frame.frame))
            #expect(try tvOpener.next() == plaintext)
        } else {
            #expect(try tvSealer.seal(plaintext).hexString == frame.frame)
            // Byte by byte, as a slow stream would deliver it.
            for byte in Data(hex: frame.frame) {
                #expect(try phoneOpener.next() == nil)
                phoneOpener.append(Data([byte]))
            }
            #expect(try phoneOpener.next() == plaintext)
            switch try ServerMessage(json: plaintext) {
            case .welcome(let welcome):
                #expect(welcome.udp.session == Vectors.shared.datagrams.session)
                #expect(welcome.udp.key == Data(hex: Vectors.shared.datagrams.key))
                #expect(welcome.tv.id == TVID(Vectors.shared.pairing[0].tv))
                #expect(welcome.state.power == .on)
                #expect(welcome.state.volume?.level == 40)
            case .paired(let grant):
                #expect(grant.key == Data(hex: Vectors.shared.handshakes.first { $0.mode == "session" }!.psk))
                #expect(grant.tv.id == TVID(Vectors.shared.pairing[0].tv))
            case .state(let update):
                #expect(update.fg != nil)
            case let other:
                Issue.record("unexpected \(other)")
            }
        }
    }
}

@Test func wrongKeyFailsBeforeAnyAnswer() throws {
    let vector = Vectors.shared.handshakes[0]
    var phone = NoiseHandshake(role: .initiator, prologue: Data(hex: vector.preamble), psk: Data(hex: vector.psk))
    var tv = NoiseHandshake(role: .responder, prologue: Data(hex: vector.preamble), psk: Data(repeating: 7, count: 32))
    #expect(throws: NoiseError.authenticationFailed) { try tv.readFirst(try phone.writeFirst()) }
}

@Test func datagrams() throws {
    let vectors = Vectors.shared.datagrams
    let key = Data(hex: vectors.key)
    for item in vectors.items {
        let direction = try #require(Datagram.Direction(rawValue: item.direction))
        let kind = try #require(Datagram.Kind(rawValue: item.kind))
        let header = Datagram.Header(kind: kind, session: vectors.session, sequence: item.seq)
        #expect(header.bytes.hexString == item.header)
        #expect(Datagram.nonce(direction, sequence: item.seq).hexString == item.nonce)
        let plain = Data(hex: item.plain)
        switch kind {
        case .pointer: #expect(PointerReport(plain)?.bytes == plain)
        case .ping, .pong: #expect(PingBody(plain)?.bytes == plain)
        }
        let sealed = try Datagram.seal(header, body: plain, key: key, direction: direction)
        #expect(sealed.hexString == item.packet)
        let opened = try Datagram.open(sealed, key: key, direction: direction)
        #expect(opened.header == header)
        #expect(opened.body == plain)

        var tampered = sealed
        tampered[5] ^= 1
        #expect(throws: Datagram.OpenError.authenticationFailed) { try Datagram.open(tampered, key: key, direction: direction) }
    }
}

@Test(arguments: Vectors.shared.pointer.map(\.name))
func pointer(name: String) throws {
    let sequence = Vectors.shared.pointer.first { $0.name == name }!
    var applier = PointerApplier(last: sequence.start.report)
    for step in sequence.steps {
        let report = step.totals.report
        #expect(report.bytes.hexString == step.plain)
        #expect(PointerReport(Data(hex: step.plain)) == report)
        if step.lost == true { continue }
        #expect(applier.apply(report) == (step.events ?? []).map(\.event))
    }
}
