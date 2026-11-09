import Foundation

/// A key of the TV's remote, by its protocol name.
public enum RemoteKey: String, Sendable, CaseIterable, Codable {
    case up, down, left, right, ok, back, home, exit
    /// The gear: Quick Settings.
    case menu
    case info, guide, list, more, input, power
    case volumeUp = "volup", volumeDown = "voldown", mute
    case channelUp = "chup", channelDown = "chdown"
    case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4"
    case digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"
    case red, green, yellow, blue
    case play, pause, playPause = "playpause", stop, rewind = "rew", fastForward = "ff"
    case netflix, amazon

    /// Keys meant to be held, which repeat on the TV: they take `down` and `up`.
    public var isHoldable: Bool {
        switch self {
        case .up, .down, .left, .right, .volumeUp, .volumeDown, .channelUp, .channelDown, .rewind, .fastForward: true
        default: false
        }
    }

    /// Home takes `tap` only: holding it is the physical remote's way out to LG.
    public var isTapOnly: Bool { self == .home }
}

public enum KeyAction: String, Sendable, Codable {
    /// A press and release, timed on the TV.
    case tap
    /// A long press, timed on the TV.
    case hold
    /// Only for holdable keys.
    case down, up
}

/// Editing in the TV's active text field.
public enum EditOperation: Sendable, Hashable {
    /// Deletes `count` characters before the caret, 1–256.
    case backspace(Int)
    case enter, tab, left, right, clear
    /// Hides or shows the TV's on-screen keyboard.
    case hide, show

    var name: String {
        switch self {
        case .backspace: "backspace"
        case .enter: "enter"
        case .tab: "tab"
        case .left: "left"
        case .right: "right"
        case .clear: "clear"
        case .hide: "hide"
        case .show: "show"
        }
    }
}

/// An id from a list, sent back as it came: the TV may use strings or numbers.
public enum ItemID: Sendable, Hashable, Codable, CustomStringConvertible {
    case string(String)
    case number(Int64)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        }
    }
}

/// A LumaTV action (`act.do`), answered by `done`.
public enum TVAction: Sendable, Hashable {
    /// LumaTV Home.
    case home
    case quickSettings
    /// Settings, or one page of it.
    case settings(page: String?)
    case notifications
    case inputPicker
    /// Screen off, sound on.
    case pictureOff
    /// The camera panel; needs the cameras plugin.
    case cameras
    /// One camera's popup.
    case camera(ItemID)
    case closeCamera
    case guide
    case tune(channel: ItemID)
    case launch(app: ItemID)
    /// The receiver's level; needs the receiver plugin.
    case volume(level: Double)
    case power(on: Bool)

    /// The protocol name, as `state.acts` lists it.
    public var name: String {
        switch self {
        case .home: "home"
        case .quickSettings: "quick"
        case .settings: "settings"
        case .notifications: "notifications"
        case .inputPicker: "input"
        case .pictureOff: "pictureoff"
        case .cameras: "cameras"
        case .camera: "camera"
        case .closeCamera: "camera-close"
        case .guide: "guide"
        case .tune: "tune"
        case .launch: "launch"
        case .volume: "volume"
        case .power: "power"
        }
    }
}

public enum ListKind: String, Sendable, Codable, CaseIterable {
    case apps, channels, cameras
}

/// A message from the phone to the TV.
public enum ClientMessage: Sendable, Hashable, Encodable {
    /// Pairing mode's only message.
    case pair(PhoneInfo)
    /// A session's first frame.
    case hello(PhoneInfo, kit: String)
    case key(RemoteKey, KeyAction)
    /// 1–256 bytes of UTF-8 without control characters; `textMessages(for:)` splits longer text.
    case text(String)
    case edit(EditOperation)
    case act(id: UInt32, TVAction)
    case get(id: UInt32, ListKind)
    case ping(UInt32)
    case bye

    public static let textLimit = 256

    /// `text` frames for any string: control characters dropped, split at character boundaries into
    /// pieces of at most 256 bytes.
    public static func textMessages(for text: String) -> [ClientMessage] {
        var messages: [ClientMessage] = []
        var piece = ""
        var pieceBytes = 0
        for character in text where !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            let bytes = character.utf8.count
            guard bytes <= textLimit else { continue }
            if pieceBytes + bytes > textLimit {
                messages.append(.text(piece))
                piece = ""
                pieceBytes = 0
            }
            piece.append(character)
            pieceBytes += bytes
        }
        if !piece.isEmpty { messages.append(.text(piece)) }
        return messages
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Member.self)
        func put(_ name: String, _ value: some Encodable) throws {
            try container.encode(value, forKey: Member(name))
        }
        switch self {
        case .pair(let phone):
            try put("t", "pair")
            try put("name", phone.name)
            try put("model", phone.model)
            try put("app", phone.app)
        case .hello(let phone, let kit):
            try put("t", "hello")
            try put("name", phone.name)
            try put("model", phone.model)
            try put("app", phone.app)
            try put("kit", kit)
        case .key(let key, let action):
            try put("t", "key")
            try put("k", key.rawValue)
            try put("a", action.rawValue)
        case .text(let text):
            try put("t", "text")
            try put("s", text)
        case .edit(let operation):
            try put("t", "edit")
            try put("op", operation.name)
            if case .backspace(let count) = operation { try put("n", count) }
        case .act(let id, let action):
            try put("t", "act")
            try put("id", id)
            try put("do", action.name)
            switch action {
            case .settings(let page): if let page { try put("page", page) }
            case .camera(let camera): try put("camera", camera)
            case .tune(let channel): try put("channel", channel)
            case .launch(let app): try put("app", app)
            case .volume(let level): try put("level", level)
            case .power(let on): try put("to", on ? "on" : "off")
            case .home, .quickSettings, .notifications, .inputPicker, .pictureOff, .cameras, .closeCamera, .guide: break
            }
        case .get(let id, let kind):
            try put("t", "get")
            try put("id", id)
            try put("what", kind.rawValue)
        case .ping(let number):
            try put("t", "ping")
            try put("n", number)
        case .bye:
            try put("t", "bye")
        }
    }
}

struct Member: CodingKey {
    let stringValue: String
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == Member {
    /// A whole number the TV may have written as a float (`3.0`): rounded to nearest, halves away from zero.
    /// A member of the wrong type is nil, so one bad member never fails the message around it.
    func lenientInt(_ name: String) -> Int? {
        let key = Member(name)
        if let whole = try? decodeIfPresent(Int.self, forKey: key) { return whole }
        guard let real = try? decodeIfPresent(Double.self, forKey: key), real.isFinite,
              abs(real) < 1e15 else { return nil }
        return Int(real.rounded())
    }

    /// A number written as an int or a float (the receiver's level moves in 0.5 steps).
    func lenientDouble(_ name: String) -> Double? {
        guard let real = try? decodeIfPresent(Double.self, forKey: Member(name)), real.isFinite else { return nil }
        return real
    }

    func lenient<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        (try? decodeIfPresent(type, forKey: Member(name))) ?? nil
    }
}

// MARK: TV to phone

public struct TVInfo: Sendable, Hashable, Codable {
    public var id: TVID
    public var name: String
    public var mac: String
    /// The TV theme's accent as `#rrggbb`; only `welcome` carries it.
    public var accent: String?
}

public enum PowerState: Sendable, Hashable, Decodable {
    case on
    /// Screen off: only the `power` key, `ping` and `bye` work.
    case standby

    public init(from decoder: any Decoder) throws {
        self = try decoder.singleValueContainer().decode(String.self) == "standby" ? .standby : .on
    }
}

/// The TV's active text field, as far as the phone may know it: its kind, never its text.
public struct IMEState: Sendable, Hashable, Decodable {
    public enum Purpose: Int, Sendable {
        case normal, alpha, digits, number, phone, url, email, name, password, date, time, dateTime, terminal
    }

    public enum Enter: Int, Sendable {
        case standard, newline, done, go, send, search, next, previous
    }

    public var active: Bool
    /// `app` or `lumatv`.
    public var owner: String?
    public var purpose: Int?
    public var hint: Int?
    public var enter: Int?
    /// The length limit; 0 is none.
    public var max: Int?
    /// Whether the field holds any text.
    public var text: Bool?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Member.self)
        active = try c.decode(Bool.self, forKey: Member("active"))
        owner = c.lenient(String.self, "owner")
        purpose = c.lenientInt("purpose")
        hint = c.lenientInt("hint")
        enter = c.lenientInt("enter")
        max = c.lenientInt("max")
        text = c.lenient(Bool.self, "text")
    }

    public static let inactive = IMEState(active: false)

    public init(active: Bool, owner: String? = nil, purpose: Int? = nil, hint: Int? = nil, enter: Int? = nil, max: Int? = nil, text: Bool? = nil) {
        self.active = active
        self.owner = owner
        self.purpose = purpose
        self.hint = hint
        self.enter = enter
        self.max = max
        self.text = text
    }

    public var purposeKind: Purpose { purpose.flatMap(Purpose.init(rawValue:)) ?? .normal }
    public var enterKind: Enter { enter.flatMap(Enter.init(rawValue:)) ?? .standard }
    public var lowercase: Bool { (hint ?? 0) & 0x08 != 0 }
    public var uppercase: Bool { (hint ?? 0) & 0x10 != 0 }
    public var titlecase: Bool { (hint ?? 0) & 0x20 != 0 }
    public var hiddenText: Bool { (hint ?? 0) & 0x40 != 0 || purposeKind == .password }
    public var sensitive: Bool { (hint ?? 0) & 0x80 != 0 }
}

public struct VolumeState: Sendable, Hashable, Decodable {
    /// The Denon's display: whole numbers bare, halves with one decimal (`51`, `50.5`).
    public static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// `receiver` or `tv`.
    public var via: String?
    /// The receiver's level and ceiling, in 0.5 steps.
    public var level: Double?
    public var max: Double?
    public var muted: Bool?

    public init(via: String? = nil, level: Double? = nil, max: Double? = nil, muted: Bool? = nil) {
        self.via = via
        self.level = level
        self.max = max
        self.muted = muted
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Member.self)
        via = c.lenient(String.self, "via")
        level = c.lenientDouble("level")
        max = c.lenientDouble("max")
        muted = c.lenient(Bool.self, "muted")
    }
}

/// The members of `state` that changed; `welcome` carries all of them. A member that does not decode is
/// dropped (left unchanged on the phone) rather than failing the message.
public struct TVStateUpdate: Sendable, Hashable, Decodable {
    public var power: PowerState?
    /// The webOS id of the app holding keyboard focus; empty while LumaTV's own layer has it.
    public var fg: String?
    public var ime: IMEState?
    public var volume: VolumeState?
    /// The `act.do` names that work right now.
    public var acts: [String]?

    public init(power: PowerState? = nil, fg: String? = nil, ime: IMEState? = nil, volume: VolumeState? = nil, acts: [String]? = nil) {
        self.power = power
        self.fg = fg
        self.ime = ime
        self.volume = volume
        self.acts = acts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Member.self)
        power = c.lenient(PowerState.self, "power")
        fg = c.lenient(String.self, "fg")
        ime = c.lenient(IMEState.self, "ime")
        volume = c.lenient(VolumeState.self, "volume")
        acts = c.lenient([String].self, "acts")
    }
}

/// The phone's picture of the TV, kept up to date from `welcome` and `state`.
public struct TVState: Sendable, Hashable {
    public static let marqueeApp = "com.beb.plxnative"

    public var power: PowerState = .on
    public var foreground = ""
    public var ime: IMEState = .inactive
    public var volume: VolumeState?
    public var actions: Set<String> = []

    public init() {}

    public mutating func apply(_ update: TVStateUpdate) {
        if let power = update.power { self.power = power }
        if let foreground = update.fg { self.foreground = foreground }
        if let ime = update.ime { self.ime = ime }
        if let volume = update.volume { self.volume = volume }
        if let acts = update.acts { actions = Set(acts) }
    }

    public var isMarqueeInFront: Bool { foreground == Self.marqueeApp }

    public func allows(_ action: TVAction) -> Bool { actions.contains(action.name) }
}

public struct UDPGrant: Sendable, Hashable, Decodable {
    public var session: UInt32
    /// 32 bytes, base64 on the wire.
    public var key: Data
}

public struct Welcome: Sendable, Hashable, Decodable {
    public var v: Int
    public var device: String
    public var tv: TVInfo
    public var udp: UDPGrant
    public var state: TVStateUpdate
}

/// What the TV sends once inside the pairing session.
public struct PairingGrant: Sendable, Hashable, Decodable {
    public var device: String
    /// The phone's 32-byte session key, base64 on the wire.
    public var key: Data
    public var tv: TVInfo
}

public struct ListItem: Sendable, Hashable, Decodable, Identifiable {
    public var id: ItemID
    /// Apps carry a title; channels and cameras a name.
    public var title: String?
    public var name: String?
    /// A channel's number.
    public var no: String?

    public var label: String { title ?? name ?? id.description }

    enum CodingKeys: String, CodingKey { case id, title, name, no }

    public init(id: ItemID, title: String? = nil, name: String? = nil, no: String? = nil) {
        self.id = id
        self.title = title
        self.name = name
        self.no = no
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ItemID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        no = try container.decodeIfPresent(ItemID.self, forKey: .no)?.description
    }
}

public struct ListPage: Sendable, Hashable, Decodable {
    public var id: UInt32
    public var what: String
    public var items: [ListItem]
    public var more: Bool
}

/// A message from the TV to the phone.
public enum ServerMessage: Sendable, Hashable {
    case paired(PairingGrant)
    case welcome(Welcome)
    case state(TVStateUpdate)
    case done(id: UInt32, error: String?)
    case list(ListPage)
    case pong(UInt32)
    /// A refused `key`, `text` or `edit`, which carry no id; `about` is the offending `t`.
    case error(code: String, about: String?)
    case revoked
    /// A `t` this version does not know, ignored.
    case unknown(String)

    public init(json: Data) throws {
        let decoder = JSONDecoder()
        let tag = try decoder.decode(Tag.self, from: json)
        switch tag.t {
        case "paired": self = .paired(try decoder.decode(PairingGrant.self, from: json))
        case "welcome": self = .welcome(try decoder.decode(Welcome.self, from: json))
        case "state": self = .state(try decoder.decode(TVStateUpdate.self, from: json))
        case "done":
            let done = try decoder.decode(Done.self, from: json)
            self = .done(id: done.id, error: done.error)
        case "list": self = .list(try decoder.decode(ListPage.self, from: json))
        case "pong": self = .pong(try decoder.decode(Pong.self, from: json).n)
        case "error":
            let error = try decoder.decode(Refusal.self, from: json)
            self = .error(code: error.code, about: error.about)
        case "revoked": self = .revoked
        default: self = .unknown(tag.t)
        }
    }

    private struct Tag: Decodable { var t: String }
    private struct Done: Decodable { var id: UInt32; var error: String? }
    private struct Pong: Decodable { var n: UInt32 }
    private struct Refusal: Decodable { var code: String; var about: String? }
}
