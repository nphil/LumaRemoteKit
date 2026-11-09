#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
@testable import LumaRemoteCore
import Testing

/// The shared vectors: the TV's Rust engine checks the same file.
struct Vectors: Decodable {
    struct PairingKeyVector: Decodable { var code, tv, key: String }
    struct FrameVector: Decodable { var plaintext, frame: String }
    struct Handshake: Decodable {
        var mode, preamble, psk: String
        var initiatorEphemeral, responderEphemeral, message1, message2: String
        var phoneToTv, tvToPhone: [FrameVector]
    }
    struct DatagramVector: Decodable {
        var key: String
        var direction: UInt8
        var kind: UInt8
        var session, sequence: UInt32
        var body, datagram: String
    }
    struct Report: Decodable {
        var x, y, scrollX, scrollY: Int32
        var held, left, right, centres, flags: UInt8
        var bytes: String
        var events: [String]?

        var report: PointerReport {
            var report = PointerReport()
            report.x = x
            report.y = y
            report.scrollX = scrollX
            report.scrollY = scrollY
            report.held = .init(rawValue: held)
            report.leftPresses = left
            report.rightPresses = right
            report.centres = centres
            report.flags = .init(rawValue: flags)
            return report
        }
    }
    struct Sequence: Decodable {
        var name: String
        var start: Report?
        var reports: [Report]
    }

    var version: Int
    var pairingKeys: [PairingKeyVector]
    var handshakes: [Handshake]
    var datagrams: [DatagramVector]
    var pointerSequences: [Sequence]

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

@Test func pairingKeys() {
    for vector in Vectors.shared.pairingKeys {
        let key = PairingKey.derive(code: PairingCode(vector.code)!, tv: TVID(vector.tv)!)
        #expect(key.hexString == vector.key)
    }
}

@Test(arguments: Vectors.shared.handshakes.map(\.mode))
func handshake(mode: String) throws {
    let vector = Vectors.shared.handshakes.first { $0.mode == mode }!
    let preamble = Data(hex: vector.preamble)
    #expect(preamble == Preamble.bytes(mode == "session" ? .session : .pairing))
    let psk = Data(hex: vector.psk)
    var phone = NoiseHandshake(role: .initiator, prologue: preamble, psk: psk,
                               ephemeral: try .init(rawRepresentation: Data(hex: vector.initiatorEphemeral)))
    var tv = NoiseHandshake(role: .responder, prologue: preamble, psk: psk,
                            ephemeral: try .init(rawRepresentation: Data(hex: vector.responderEphemeral)))

    let first = try phone.writeFirst()
    #expect(first.hexString == vector.message1)
    try tv.readFirst(first)
    let (second, tvSession) = try tv.writeSecond()
    #expect(second.hexString == vector.message2)
    let phoneSession = try phone.readSecond(second)

    var phoneSealer = FrameSealer(cipher: phoneSession.send)
    var tvOpener = FrameOpener(cipher: tvSession.receive)
    for frame in vector.phoneToTv {
        #expect(try phoneSealer.seal(Data(frame.plaintext.utf8)).hexString == frame.frame)
        tvOpener.append(Data(hex: frame.frame))
        #expect(try tvOpener.next() == Data(frame.plaintext.utf8))
    }
    var tvSealer = FrameSealer(cipher: tvSession.send)
    var phoneOpener = FrameOpener(cipher: phoneSession.receive)
    for frame in vector.tvToPhone {
        #expect(try tvSealer.seal(Data(frame.plaintext.utf8)).hexString == frame.frame)
        // Byte by byte, as a slow stream would deliver it.
        for byte in Data(hex: frame.frame) {
            #expect(try phoneOpener.next() == nil)
            phoneOpener.append(Data([byte]))
        }
        let plaintext = try #require(try phoneOpener.next())
        #expect(plaintext == Data(frame.plaintext.utf8))
        _ = try ServerMessage(json: plaintext)
    }
}

@Test func wrongKeyFailsBeforeAnyAnswer() throws {
    let vector = Vectors.shared.handshakes[0]
    var phone = NoiseHandshake(role: .initiator, prologue: Data(hex: vector.preamble), psk: Data(hex: vector.psk))
    var tv = NoiseHandshake(role: .responder, prologue: Data(hex: vector.preamble), psk: Data(repeating: 7, count: 32))
    #expect(throws: NoiseError.authenticationFailed) { try tv.readFirst(try phone.writeFirst()) }
}

@Test func datagrams() throws {
    for vector in Vectors.shared.datagrams {
        let key = Data(hex: vector.key)
        let direction = try #require(Datagram.Direction(rawValue: vector.direction))
        let header = Datagram.Header(kind: try #require(Datagram.Kind(rawValue: vector.kind)), session: vector.session, sequence: vector.sequence)
        let sealed = try Datagram.seal(header, body: Data(hex: vector.body), key: key, direction: direction)
        #expect(sealed.hexString == vector.datagram)
        let opened = try Datagram.open(sealed, key: key, direction: direction)
        #expect(opened.header == header)
        #expect(opened.body.hexString == vector.body)

        var tampered = sealed
        tampered[5] ^= 1
        #expect(throws: Datagram.OpenError.authenticationFailed) { try Datagram.open(tampered, key: key, direction: direction) }
    }
}

@Test(arguments: Vectors.shared.pointerSequences.map(\.name))
func pointerTotals(name: String) throws {
    let sequence = Vectors.shared.pointerSequences.first { $0.name == name }!
    var applier = PointerApplier(last: sequence.start?.report ?? PointerReport())
    for step in sequence.reports {
        let report = step.report
        #expect(report.bytes.hexString == step.bytes)
        #expect(PointerReport(Data(hex: step.bytes)) == report)
        #expect(applier.apply(report).map(\.description) == step.events)
    }
}
