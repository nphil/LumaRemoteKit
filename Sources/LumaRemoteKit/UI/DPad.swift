#if os(iOS)
import LumaRemoteCore
import SwiftUI

/// The navigation pad: arrows around the select key, pressed where the finger lands. A finger that
/// slides instead steps one arrow for every 44 points it travels.
struct DPadView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var touching = false
    @State private var pressed: RemoteKey?
    @State private var landed: RemoteKey?
    @State private var swipe: SwipeTracker?

    /// The select key's share of the pad's width.
    private static let centre: CGFloat = 0.42

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            plate(side: side)
                .frame(width: side, height: side)
                .contentShape(Circle())
                .gesture(drag(side: side))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .opacity(isEnabled ? 1 : 0.38)
        .onChange(of: touching) { _, touching in
            if !touching { finish(cancelled: true) }
        }
        .accessibilityRepresentation {
            VStack {
                Button("Up") { model.tap(.up) }
                HStack {
                    Button("Left") { model.tap(.left) }
                    Button("Select") { model.tap(.ok) }
                    Button("Right") { model.tap(.right) }
                }
                Button("Down") { model.tap(.down) }
            }
        }
        .accessibilityIdentifier("remote.dpad")
    }

    private func plate(side: CGFloat) -> some View {
        let palette = theme.palette
        let reach = side * 0.37
        return ZStack {
            Circle().fill(palette.surface)
            Circle().strokeBorder(palette.edge, lineWidth: 0.5)
            if let pressed, let angle = Self.angle(of: pressed) {
                Wedge(direction: angle, inner: Self.centre).fill(palette.focus)
            }
            ForEach([RemoteKey.up, .right, .down, .left], id: \.self) { key in
                let angle = Self.angle(of: key)!.radians
                Image(systemName: "chevron.\(key.rawValue)")
                    .font(.system(size: KeyMetrics.glyph, weight: .semibold))
                    .foregroundStyle(pressed == key ? palette.ink : palette.ink2)
                    .offset(x: reach * cos(angle), y: reach * sin(angle))
            }
            Circle()
                .fill(palette.surfaceRaised)
                .overlay(Circle().fill(palette.focus).opacity(pressed == .ok ? 1 : 0))
                .overlay(Circle().strokeBorder(palette.edge, lineWidth: 0.5))
                .frame(width: side * Self.centre, height: side * Self.centre)
        }
    }

    private func drag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { value in
                let haptics = Haptics(enabled: model.settings.haptics)
                if landed == nil, swipe == nil {
                    let key = Self.key(at: value.startLocation, side: side)
                    landed = key
                    pressed = key
                    haptics.press()
                    model.pressBegan(key)
                    swipe = SwipeTracker(x: value.startLocation.x, y: value.startLocation.y)
                }
                if let key = landed, hypot(value.translation.width, value.translation.height) > SwipeTracker.slop {
                    landed = nil
                    pressed = nil
                    model.pressCancelled(key)
                }
                guard landed == nil, let steps = swipe?.move(x: value.location.x, y: value.location.y) else { return }
                for key in steps {
                    haptics.tick()
                    model.tap(key)
                }
            }
            .onEnded { _ in finish(cancelled: false) }
    }

    private func finish(cancelled: Bool) {
        if let landed {
            if cancelled { model.pressCancelled(landed) } else { model.pressEnded(landed) }
        }
        landed = nil
        pressed = nil
        swipe = nil
    }

    /// The key under a point of a pad `side` points across.
    static func key(at point: CGPoint, side: CGFloat) -> RemoteKey {
        let dx = point.x - side / 2
        let dy = point.y - side / 2
        if hypot(dx, dy) < side * centre / 2 { return .ok }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    /// The direction an arrow points, clockwise from the right as the screen draws it.
    private static func angle(of key: RemoteKey) -> Angle? {
        switch key {
        case .right: .degrees(0)
        case .down: .degrees(90)
        case .left: .degrees(180)
        case .up: .degrees(270)
        default: nil
        }
    }
}

/// A quarter of a ring, centred on `direction`.
private struct Wedge: Shape {
    var direction: Angle
    /// The hole's diameter as a share of the ring's.
    var inner: CGFloat

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(center: centre, radius: radius, startAngle: direction - .degrees(45), endAngle: direction + .degrees(45), clockwise: false)
        path.addArc(center: centre, radius: radius * inner, startAngle: direction + .degrees(45), endAngle: direction - .degrees(45), clockwise: true)
        path.closeSubpath()
        return path
    }
}
#endif
