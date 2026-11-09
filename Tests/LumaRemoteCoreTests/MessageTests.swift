import Foundation
@testable import LumaRemoteCore
import Testing

private func object(_ message: ClientMessage) throws -> NSDictionary {
    try JSONSerialization.jsonObject(with: message.json()) as! NSDictionary
}

@Test func clientMessagesEncode() throws {
    #expect(try object(.key(.volumeUp, .down)) == ["t": "key", "k": "volup", "a": "down"])
    #expect(try object(.edit(.backspace(3))) == ["t": "edit", "op": "backspace", "n": 3])
    #expect(try object(.edit(.enter)) == ["t": "edit", "op": "enter"])
    #expect(try object(.act(id: 4, .tune(channel: .string("c1")))) == ["t": "act", "id": 4, "do": "tune", "channel": "c1"])
    #expect(try object(.act(id: 5, .power(on: false))) == ["t": "act", "id": 5, "do": "power", "to": "off"])
    #expect(try object(.act(id: 6, .settings(page: nil))) == ["t": "act", "id": 6, "do": "settings"])
    #expect(try object(.get(id: 7, .channels)) == ["t": "get", "id": 7, "what": "channels"])
    #expect(try object(.act(id: 8, .volume(level: 50.5))) == ["t": "act", "id": 8, "do": "volume", "level": 50.5])
    let phone = PhoneInfo(name: "  Kitchen  ", model: "iPhone17,1", app: "Marquee 0.1")
    #expect(try object(.hello(phone, kit: "LumaRemoteKit 1.0.0"))
        == ["t": "hello", "name": "Kitchen", "model": "iPhone17,1", "app": "Marquee 0.1", "kit": "LumaRemoteKit 1.0.0"])
}

@Test func textSplitsAtCharactersWithinTheLimit() {
    let long = String(repeating: "é", count: 200) + "\u{7}" + "👍🏽"
    let pieces = ClientMessage.textMessages(for: long).map { message -> String in
        guard case .text(let text) = message else { return "" }
        return text
    }
    #expect(pieces.allSatisfy { $0.utf8.count <= ClientMessage.textLimit })
    #expect(pieces.joined() == String(repeating: "é", count: 200) + "👍🏽")
    #expect(ClientMessage.textMessages(for: "\n").isEmpty)
}

@Test func serverMessagesDecode() throws {
    func decode(_ json: String) throws -> ServerMessage { try ServerMessage(json: Data(json.utf8)) }
    #expect(try decode(#"{"t":"done","id":3,"error":"off"}"#) == .done(id: 3, error: "off"))
    #expect(try decode(#"{"t":"error","code":"no-field","about":"text"}"#) == .error(code: "no-field", about: "text"))
    #expect(try decode(#"{"t":"later","x":1}"#) == .unknown("later"))
    guard case .list(let page) = try decode(#"{"t":"list","id":2,"what":"channels","items":[{"id":"c1","no":1,"name":"One"}],"more":false}"#) else {
        Issue.record("not a list")
        return
    }
    #expect(page.items == [ListItem(id: .string("c1"), name: "One", no: "1")])

    var state = TVState()
    guard case .state(let update) = try decode(#"{"t":"state","fg":"com.beb.plxnative","ime":{"active":true,"purpose":8,"hint":64},"acts":["guide"],"later":1}"#) else {
        Issue.record("not a state")
        return
    }
    state.apply(update)
    #expect(state.isMarqueeInFront)
    #expect(state.ime.hiddenText)
    #expect(state.allows(.guide) && !state.allows(.cameras))
}

@Test func pairingCodesAndLinks() throws {
    #expect(PairingCode(" luma-2345 ")?.characters == "LUMA2345")
    #expect(PairingCode("LUMA2345")?.description == "LUMA-2345")
    #expect(PairingCode("LUMA234O") == nil)
    #expect(PairingCode("LUMA234") == nil)

    let link = try #require(URL(string: "lumaremote://pair?h=192.168.1.242&p=18733&id=5a1c0ffee0ddba11&c=LUMA2345"))
    let invite = try #require(PairingInvite(url: link))
    #expect(invite.host == "192.168.1.242" && invite.port == 18733 && invite.tv.description == "5a1c0ffee0ddba11")
    #expect(PairingInvite(url: invite.url) == invite)
    #expect(PairingInvite(url: URL(string: "lumaremote://pair?h=x&id=zz&c=LUMA2345")!) == nil)
}

@Test func advertisementsAndWakePackets() throws {
    let tv = try #require(TVAdvertisement(service: "LG C4", txt: ["v": "1", "id": "5a1c0ffee0ddba11", "name": "Lounge", "mac": "74c17ebdae30", "pair": "1"]))
    #expect(tv.name == "Lounge" && tv.pairingOpen && tv.isSupported)
    #expect(TVAdvertisement(service: "LG C4", txt: ["v": "2", "id": "5a1c0ffee0ddba11"])?.isSupported == false)
    #expect(TVAdvertisement(service: "LG C4", txt: ["v": "1"]) == nil)

    let packet = try #require(WakeOnLAN.magicPacket(mac: "74:c1:7e:bd:ae:30"))
    #expect(packet.count == 102)
    #expect(packet.prefix(6) == Data(repeating: 0xFF, count: 6))
    #expect(packet.suffix(6) == Data(hexString: "74c17ebdae30"))
    #expect(WakeOnLAN.magicPacket(mac: "74:c1") == nil)
}

@Test func accumulatorCarriesFractions() {
    var accumulator = PointerAccumulator()
    for _ in 0..<10 { accumulator.move(dx: 0.05, dy: -0.05) }
    #expect(accumulator.report.x == 8 && accumulator.report.y == -8)
    accumulator.press(.left)
    accumulator.release(.left)
    accumulator.click(.left)
    #expect(accumulator.report.leftPresses == 2 && accumulator.report.held.isEmpty)
}

@Test func stateDecodesLeniently() throws {
    func decode(_ json: String) throws -> ServerMessage { try ServerMessage(json: Data(json.utf8)) }
    let head = #"{"t":"welcome","v":1,"device":"0123456789abcdef","tv":{"id":"0a010203040506ff","name":"TV","mac":""},"udp":{"session":1,"key":"QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI="},"state":"#
    guard case .welcome(let welcome) = try decode(head + #"{"power":"on","volume":{"via":"receiver","level":50.0,"max":72.5,"muted":false},"ime":{"active":true,"max":3.0}}}"#) else {
        Issue.record("not a welcome")
        return
    }
    #expect(welcome.state.volume == VolumeState(via: "receiver", level: 50, max: 72.5, muted: false))
    #expect(welcome.state.ime?.max == 3)

    // One undecodable member is dropped; its siblings and the message survive.
    guard case .welcome(let partial) = try decode(head + #"{"power":"on","ime":{"active":"yes"},"volume":{"level":"loud","max":72.5},"acts":["home"]}}"#) else {
        Issue.record("not a welcome")
        return
    }
    #expect(partial.state.ime == nil && partial.state.power == .on && partial.state.acts == ["home"])
    #expect(partial.state.volume == VolumeState(level: nil, max: 72.5))
    guard case .state(let update) = try decode(#"{"t":"state","volume":{"level":50.5},"fg":7}"#) else {
        Issue.record("not a state")
        return
    }
    #expect(update.volume?.level == 50.5 && update.fg == nil)
    #expect(VolumeState.format(50.5) == "50.5" && VolumeState.format(51) == "51")
    #expect(throws: DecodingError.self) { try decode(#"{"t":"welcome","v":1}"#) }
}
