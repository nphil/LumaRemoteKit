#if os(iOS)
import CoreMotion
import LumaRemoteCore
import SwiftUI

/// Turns the phone's turns into pointer motion. Device motion arrives at 100 Hz on the mouse's own queue
/// and goes straight out from there; everything below `motion` is touched only on that queue.
final class AirMouse: @unchecked Sendable {
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LumaRemote.airmouse"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    private var pointer: PointerSender?
    private var pointing = false
    private var speed = 1.0
    private var frozenUntil = 0.0
    private var lastTime: Double?
    private var filterX = OneEuroFilter(minimumCutoff: 1.0, beta: 0.004)
    private var filterY = OneEuroFilter(minimumCutoff: 1.0, beta: 0.004)

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    func start(_ pointer: PointerSender) {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        queue.addOperation { self.pointer = pointer }
        motion.deviceMotionUpdateInterval = 1.0 / 100
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.apply(data)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        queue.addOperation {
            self.pointer = nil
            self.pointing = false
        }
    }

    /// Whether turns move the pointer; each start begins from rest.
    func setPointing(_ on: Bool) {
        queue.addOperation {
            guard self.pointing != on else { return }
            self.pointing = on
            self.lastTime = nil
            self.filterX.reset()
            self.filterY.reset()
        }
    }

    /// The setting that scales the gain, 0.5–2.
    func setSpeed(_ speed: Double) {
        queue.addOperation { self.speed = speed }
    }

    /// Holds the pointer still while a press lands or lifts, so the press itself does not move it.
    func freeze(for seconds: Double = 0.1) {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        queue.addOperation { self.frozenUntil = max(self.frozenUntil, until) }
    }

    private func apply(_ data: CMDeviceMotion) {
        let time = data.timestamp
        defer { lastTime = time }
        guard pointing, let pointer, let last = lastTime else { return }
        let interval = time - last
        guard interval > 0, interval < 0.1 else { return }
        let rotation = data.rotationRate
        let gravity = data.gravity
        let rates = AirMouseMath.pointerRates(
            rotation: .init(x: rotation.x, y: rotation.y, z: rotation.z),
            gravity: .init(x: gravity.x, y: gravity.y, z: gravity.z)
        )
        let x = filterX.filter(rates.x, interval: interval)
        let y = filterY.filter(rates.y, interval: interval)
        guard time >= frozenUntil else { return }
        let scale = AirMouseMath.gain * AirMouseMath.acceleration((x * x + y * y).squareRoot()) * speed * interval
        pointer.move(dx: x * scale, dy: y * scale)
    }
}

/// The air mouse's pad. Hold to point: the pointer follows the phone while a thumb rests on the pad, a
/// tap clicks, and a tap then a hold drags. Always on: the pointer follows the phone, a tap clicks and a
/// hold past 350 ms drags.
struct PointerPadView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @GestureState private var touching = false
    @State private var mouse = AirMouse()
    @State private var down: Date?
    @State private var lastTap: Date?
    @State private var holding = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var disengage: Task<Void, Never>?

    private static let tapTime = 0.25
    private static let tapTravel: CGFloat = 10
    private static let doubleTapWindow = 0.3
    private static let dragHold = Duration.milliseconds(350)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radii.surface, style: .continuous)
        VStack(spacing: KeyMetrics.gap) {
            shape.fill(down != nil ? theme.palette.focus : theme.palette.surface)
                .overlay(shape.strokeBorder(theme.palette.edge, lineWidth: 0.5))
                .overlay {
                    Image(systemName: mouse.isAvailable ? "hand.point.up.left" : "iphone.slash")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(theme.palette.ink3)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .gesture(press)
                .disabled(!mouse.isAvailable)
                .accessibilityElement()
                .accessibilityLabel(Text(mouse.isAvailable ? "Pointer pad" : "Motion isn't available on this device"))
                .accessibilityHint(Text("Hold a thumb here and turn the phone to point. Tap to click."))
                .accessibilityAddTraits(.allowsDirectInteraction)
                .accessibilityIdentifier("remote.pointerpad")
            GlyphButton(symbol: "scope", label: "Centre the pointer") {
                model.pointer.centre()
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: model.settings.pointerSpeed) { _, speed in mouse.setSpeed(speed) }
        .onChange(of: model.settings.pointerMode) { _, _ in
            stop()
            start()
        }
        .onChange(of: touching) { _, touching in
            if !touching, down != nil { lift(quick: false) }
        }
    }

    private var alwaysOn: Bool { model.settings.pointerMode == .alwaysOn }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { _ in
                if down == nil { land() }
            }
            .onEnded { value in
                let quick = Date.now.timeIntervalSince(down ?? .now) <= Self.tapTime
                    && hypot(value.translation.width, value.translation.height) <= Self.tapTravel
                lift(quick: quick)
            }
    }

    private func start() {
        mouse.setSpeed(model.settings.pointerSpeed)
        mouse.start(model.pointer)
        if alwaysOn { engage(true) }
    }

    private func stop() {
        holdTimer?.cancel()
        if holding { model.pointer.release(.left) }
        holding = false
        down = nil
        mouse.setPointing(false)
        mouse.stop()
        disengage?.cancel()
        model.pointer.set(.engaged, false)
    }

    private func land() {
        let now = Date.now
        down = now
        mouse.freeze()
        let haptics = Haptics(enabled: model.settings.haptics)
        haptics.press()
        engage(true)
        if alwaysOn {
            holdTimer = Task {
                try? await Task.sleep(for: Self.dragHold)
                guard !Task.isCancelled, down != nil else { return }
                holding = true
                haptics.click()
                model.pointer.press(.left)
            }
        } else if let lastTap, now.timeIntervalSince(lastTap) <= Self.doubleTapWindow {
            holding = true
            model.pointer.press(.left)
        }
    }

    private func lift(quick: Bool) {
        holdTimer?.cancel()
        holdTimer = nil
        mouse.freeze()
        if holding {
            model.pointer.release(.left)
            lastTap = nil
        } else if quick {
            Haptics(enabled: model.settings.haptics).click()
            model.pointer.click(.left)
            lastTap = .now
        }
        holding = false
        down = nil
        if !alwaysOn { engage(false) }
    }

    /// Pointing on at once; off a second after the thumb lifts, when the TV hides the pointer.
    private func engage(_ on: Bool) {
        disengage?.cancel()
        if on {
            mouse.setPointing(true)
            model.pointer.set(.engaged, true)
            return
        }
        mouse.setPointing(false)
        let pointer = model.pointer
        disengage = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { pointer.set(.engaged, false) }
        }
    }
}
#endif
