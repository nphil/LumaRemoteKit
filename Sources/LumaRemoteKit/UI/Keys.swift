#if os(iOS)
import LumaRemoteCore
import SwiftUI

/// The remote's one key size and the gap between keys.
enum KeyMetrics {
    static let size: CGFloat = 56
    static let gap: CGFloat = 12
    static let glyph: CGFloat = 20
    /// A finger that slides this far from where it landed has left the key.
    static let slideOff: CGFloat = 28
}

enum KeyStyle {
    /// A raised disc of its own.
    case raised
    /// No disc: the key sits on a shared plate, such as a rocker.
    case onPlate
    case accent
}

/// A key's disc around its glyph, washed with the focus colour while pressed.
struct KeyDisc: ViewModifier {
    var style: KeyStyle
    var pressed: Bool

    @Environment(\.lumaRemoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .font(.system(size: KeyMetrics.glyph, weight: .semibold))
            .foregroundStyle(style == .accent ? theme.palette.accentInk : theme.palette.ink)
            .frame(width: KeyMetrics.size, height: KeyMetrics.size)
            .background {
                ZStack {
                    switch style {
                    case .raised: Circle().fill(theme.palette.surfaceRaised)
                    case .accent: Circle().fill(theme.palette.accent)
                    case .onPlate: EmptyView()
                    }
                    Circle().fill(theme.palette.focus).opacity(pressed ? 1 : 0)
                }
            }
            .contentShape(Circle())
            .scaleEffect(pressed && !reduceMotion ? 0.93 : 1)
            .animation(reduceMotion ? nil : Animation.snappy(duration: 0.15), value: pressed)
            .opacity(isEnabled ? 1 : 0.38)
    }
}

/// A plain button drawn as a key.
struct KeyButtonStyle: ButtonStyle {
    var style = KeyStyle.raised

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(KeyDisc(style: style, pressed: configuration.isPressed))
    }
}

/// A remote key: its wire key, glyph and spoken name.
struct KeySpec {
    let key: RemoteKey
    let symbol: String
    let label: String
}

/// Sends a key from a finger on the view, as the physical remote would: down when the finger lands,
/// then a tap, a repeat or a long press by how long it stays. Sliding off lets go without pressing.
struct KeyPressGesture: ViewModifier {
    let key: RemoteKey
    @Binding var pressed: Bool

    @Environment(RemoteModel.self) private var model
    @GestureState private var touching = false
    @State private var slidOff = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { value in
                        if !pressed, !slidOff {
                            pressed = true
                            Haptics(enabled: model.settings.haptics).press()
                            model.pressBegan(key)
                        } else if pressed, hypot(value.translation.width, value.translation.height) > KeyMetrics.slideOff {
                            pressed = false
                            slidOff = true
                            model.pressCancelled(key)
                        }
                    }
                    .onEnded { _ in finish(cancelled: false) }
            )
            // A gesture the system takes over, such as a pull for Control Centre, ends without onEnded.
            .onChange(of: touching) { _, touching in
                if !touching { finish(cancelled: true) }
            }
    }

    private func finish(cancelled: Bool) {
        if pressed {
            if cancelled { model.pressCancelled(key) } else { model.pressEnded(key) }
        }
        pressed = false
        slidOff = false
    }
}

extension View {
    /// One VoiceOver button for a glyph-only control, with the large content viewer at the biggest text sizes.
    func keyAccessibility(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(action)
            .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
    }
}

/// A key that presses, holds and repeats like the remote's.
struct RemoteKeyButton: View {
    let spec: KeySpec
    var style = KeyStyle.raised

    @Environment(RemoteModel.self) private var model
    @State private var pressed = false

    init(_ spec: KeySpec, style: KeyStyle = .raised) {
        self.spec = spec
        self.style = style
    }

    var body: some View {
        Image(systemName: spec.symbol)
            .modifier(KeyDisc(style: style, pressed: pressed))
            .modifier(KeyPressGesture(key: spec.key, pressed: $pressed))
            .keyAccessibility(spec.label, symbol: spec.symbol) { model.tap(spec.key) }
            .accessibilityIdentifier("remote.key.\(spec.key.rawValue)")
    }
}

/// A key that runs `action` on a tap.
struct GlyphButton: View {
    let symbol: String
    let label: String
    var style = KeyStyle.raised
    let action: () -> Void

    @Environment(RemoteModel.self) private var model

    var body: some View {
        Button {
            Haptics(enabled: model.settings.haptics).press()
            action()
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(KeyButtonStyle(style: style))
        .accessibilityLabel(Text(label))
        .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
    }
}

/// Three keys on one tall plate, like the remote's volume and channel rockers.
struct Rocker: View {
    let top: KeySpec
    let middle: KeySpec
    let bottom: KeySpec
    var middleStyle = KeyStyle.onPlate

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        VStack(spacing: KeyMetrics.gap) {
            RemoteKeyButton(top, style: .onPlate)
            RemoteKeyButton(middle, style: middleStyle)
            RemoteKeyButton(bottom, style: .onPlate)
        }
        .background(Capsule().fill(theme.palette.surface))
        .overlay(Capsule().strokeBorder(theme.palette.edge, lineWidth: 0.5))
    }
}
#endif
