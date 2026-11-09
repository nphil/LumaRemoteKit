#if os(iOS)
import LumaRemoteCore
import SwiftUI
import UIKit

/// The touchpad: one finger moves the pointer and taps to click, a tap then a slide drags, two fingers
/// scroll and glide on after a flick, and a two-finger tap goes back.
struct TouchpadView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @State private var touching = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radii.surface, style: .continuous)
        TouchCapture(model: model, speed: model.settings.touchpadSpeed, haptics: model.settings.haptics, touching: $touching)
            .background(shape.fill(touching ? theme.palette.focus : theme.palette.surface))
            .overlay(shape.strokeBorder(theme.palette.edge, lineWidth: 0.5))
            .overlay {
                Image(systemName: "hand.draw")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(theme.palette.ink3)
                    .opacity(touching ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .accessibilityElement()
            .accessibilityLabel(Text("Touchpad"))
            .accessibilityHint(Text("Slide one finger to move the pointer and tap to click. Slide two fingers to scroll."))
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityIdentifier("remote.touchpad")
    }
}

private struct TouchCapture: UIViewRepresentable {
    let model: RemoteModel
    let speed: Double
    let haptics: Bool
    @Binding var touching: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        view.onTouches = { count, centre, time in
            coordinator.update(count: count, centre: centre, time: time)
        }
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        let coordinator = context.coordinator
        coordinator.tracker.speed = speed
        coordinator.haptics = Haptics(enabled: haptics)
        coordinator.touching = $touching
    }

    static func dismantleUIView(_ view: TouchView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var tracker = TrackpadTracker()
        var haptics = Haptics(enabled: true)
        var touching: Binding<Bool>?
        private let model: RemoteModel
        private var glide: Task<Void, Never>?
        private var disengage: Task<Void, Never>?

        init(model: RemoteModel) {
            self.model = model
        }

        func update(count: Int, centre: CGPoint, time: TimeInterval) {
            let pointer = model.pointer
            if count > 0 {
                disengage?.cancel()
                disengage = nil
                if glide != nil {
                    glide?.cancel()
                    glide = nil
                    pointer.set(.scrolling, false)
                }
                pointer.set(.engaged, true)
            }
            touching?.wrappedValue = count > 0
            for output in tracker.update(count: count, x: centre.x, y: centre.y, time: time) {
                switch output {
                case .move(let dx, let dy): pointer.move(dx: dx, dy: dy)
                case .scroll(let dx, let dy): pointer.scroll(dx: dx, dy: dy)
                case .scrolling(let on): pointer.set(.scrolling, on)
                case .click:
                    haptics.click()
                    pointer.click(.left)
                case .press:
                    haptics.click()
                    pointer.press(.left)
                case .release: pointer.release(.left)
                case .back:
                    haptics.press()
                    model.tap(.back)
                case .fling(let dx, let dy): startGlide(dx: dx, dy: dy)
                }
            }
            if count == 0, glide == nil { scheduleDisengage() }
        }

        /// Scrolls on after a flick at 60 Hz until the speed dies away, then lifts the scroll fingers.
        private func startGlide(dx: Double, dy: Double) {
            let pointer = model.pointer
            glide = Task { [weak self] in
                var momentum = ScrollMomentum(velocityX: dx, velocityY: dy)
                let interval = 1.0 / 60
                while let step = momentum.step(interval: interval) {
                    pointer.scroll(dx: step.dx, dy: step.dy)
                    try? await Task.sleep(for: .seconds(interval))
                    if Task.isCancelled { return }
                }
                pointer.set(.scrolling, false)
                self?.glide = nil
                self?.scheduleDisengage()
            }
        }

        /// The TV hides the pointer a second after the fingers lift.
        private func scheduleDisengage() {
            let pointer = model.pointer
            disengage?.cancel()
            disengage = Task {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                pointer.set(.engaged, false)
            }
        }

        func stop() {
            glide?.cancel()
            disengage?.cancel()
            model.pointer.set(.scrolling, false)
            model.pointer.set(.engaged, false)
        }
    }
}

/// Reports every change in the fingers on it: how many, their centre and the event's time.
final class TouchView: UIView {
    var onTouches: ((Int, CGPoint, TimeInterval) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(event) }

    private func report(_ event: UIEvent?) {
        guard let event else { return }
        let down = (event.touches(for: self) ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        var sum = CGPoint.zero
        for touch in down {
            let point = touch.location(in: self)
            sum.x += point.x
            sum.y += point.y
        }
        let count = CGFloat(max(down.count, 1))
        onTouches?(down.count, CGPoint(x: sum.x / count, y: sum.y / count), event.timestamp)
    }
}
#endif
