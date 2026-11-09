# LumaRemoteKit

The iPhone side of the LumaTV phone remote: a Swift package that pairs with a LumaTV, sends the remote's keys, text and LumaTV
actions over an encrypted session, and moves the TV's pointer from the phone's motion or a touchpad. The protocol is specified
in LumaTV's `docs/research/phone-remote.md`.

| Product | Platforms | Contents |
|---|---|---|
| `LumaRemoteCore` | iOS 17, macOS 14 | Noise session, pairing, frames, messages, datagram codec, Bonjour discovery, TCP and UDP link with reconnect and keepalive, Keychain store, Wake-on-LAN |
| `LumaRemoteKit` | iOS 17 | `RemoteModel` and the SwiftUI views: `LumaRemoteView`, `PairingView`, `TVPicker`, `DiagnosticsView`, `RemoteSettingsView` |
| `LumaRemoteFakeTV` | iOS 17, macOS 14 | A loopback TV for tests and previews: the real protocol, pairing code `LUMA-2345`, and a log of what arrived |

## Adding it to an app

```swift
.package(url: "https://github.com/nphil/LumaRemoteKit", from: "1.0.0")
```

The host's Info.plist needs `NSLocalNetworkUsageDescription`, `NSBonjourServices` with `_lumatv-remote._tcp`, and
`NSCameraUsageDescription` for scanning the TV's pairing code.

```swift
let model = RemoteModel(app: "Marquee 0.1.21", services: .live())

LumaRemoteView(model: model) { showRemote = false }
    .lumaRemoteTheme(theme)
```

`app` names the host; the TV lists it beside the phone. The TV's QR code carries a `lumaremote://pair?…` link: a host that
registers the scheme passes it to `model.open(url)`, and the remote asks to confirm the pairing.

Pairings live in the Keychain under the kit's own service, so each host app pairs separately unless it passes a shared
`accessGroup` to `.live(accessGroup:)`.

## Theme

`RemoteTheme` carries a palette (canvas, surfaces, edge, three inks, accent, focus and the status colours), an optional colour
scheme, two corner radii and up to four typeface names. Without one the views use the system's colours and type. A host maps its
own tokens into it and sets it with `.lumaRemoteTheme(_:)`; the views follow changes live.

## The remote

The face carries the keys used every day: power, the D-pad (press an arrow or OK, or slide to step; held arrows repeat), Back,
Home, the gear, volume and channel rockers, the media keys, input, the guide and the keyboard. More holds the rest of the TV
remote's keys (playback, info, exit, colour keys, apps) and LumaTV's own actions while the TV offers them. There is no number
pad.

The middle pad switches between the D-pad and two pointers:

- **Air mouse:** the pointer follows the phone while a thumb rests on the pad. A tap clicks; tap, then hold, drags. Centre
  puts the pointer in the middle of the screen. In Settings it can follow the phone whenever the pad is open instead, where a
  press held past 350 ms drags.
- **Touchpad:** one finger moves the pointer, a tap clicks, tap-and-drag drags, two fingers scroll with momentum, and a
  two-finger tap is Back.

While the remote is open and the phone isn't playing sound, the phone's volume buttons step the TV's volume.

## Tests

`swift test` runs on macOS and on Linux, where the core builds against swift-crypto. The protocol tests check the codec, the
handshake and the datagrams against `Tests/LumaRemoteCoreTests/vectors.json`; CI compares that file with the copy LumaTV's Rust
test client publishes, so protocol drift fails the run.

## License

MIT
