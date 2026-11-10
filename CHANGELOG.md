# Changelog

## Unreleased

- Exposes the authenticated TV connection path and lets a host manage the remote lifecycle.

## 1.0.3

- The receiver's volume level and ceiling are numbers in 0.5 steps (`50.5`), shown with one decimal only when
  fractional; the volume act sends a number, and the phone's volume buttons step the receiver by 0.5.
- State members decode leniently: ints or floats, and one undecodable member is dropped instead of failing
  the whole welcome or state message.
- A message the kit cannot decode reports `TVLink.Status.incompatible` and `RemoteModel.Connection.incompatible`
  ("The TV answered in a way this app doesn't understand. Update Marquee or LumaTV."), with the decode error in
  Diagnostics, instead of offline.

## 1.0.2

- A closing connection sends what is still queued first; the fake TV's reply to pairing was being dropped on
  real sockets.

## 1.0.1

- A pairing link confirms on the remote itself rather than in a sheet, so pairing no longer closes a host's
  full-screen remote.

## 1.0.0

First release: protocol v1 of the LumaTV phone remote.

- Pairing by the TV's code or its QR link, with the Noise session and Keychain store.
- The remote: D-pad, media, volume and channel keys, input, guide, LumaTV's actions, keyboard bridge, the phone's volume
  buttons, an air mouse and a touchpad.
- Host theme through `.lumaRemoteTheme(_:)`, TV picker, settings and diagnostics.
- `LumaRemoteFakeTV`, a loopback TV for tests.
