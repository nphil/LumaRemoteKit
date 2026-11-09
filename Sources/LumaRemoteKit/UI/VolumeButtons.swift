#if os(iOS)
import AVFAudio
import LumaRemoteCore
import MediaPlayer
import SwiftUI
import UIKit

/// While it is on screen, the phone's volume buttons step the TV's volume. A press shows up as a change
/// in the phone's output volume; the near-invisible `MPVolumeView` keeps the system's volume overlay away
/// and lets the volume be put back towards the middle so both buttons keep registering.
///
/// It stands aside while audio is playing, from this app or another, so it never changes the level of
/// something the person is listening to.
struct VolumeButtonCatcher: UIViewRepresentable {
    let onPress: (RemoteKey) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPress: onPress)
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        context.coordinator.start(view)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        context.coordinator.onPress = onPress
    }

    static func dismantleUIView(_ view: MPVolumeView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var onPress: (RemoteKey) -> Void
        private weak var view: MPVolumeView?
        private var observation: NSKeyValueObservation?
        private var restore: (category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions, volume: Float)?
        private var last: Float?
        /// The level this catcher set itself, whose change is not a press.
        private var expected: Float?

        /// Steps nearer the ends than this move the level back to the middle, so the next press in
        /// either direction still changes it. The buttons step by 1/16.
        private static let margin: Float = 0.15

        init(onPress: @escaping (RemoteKey) -> Void) {
            self.onPress = onPress
        }

        func start(_ view: MPVolumeView) {
            let session = AVAudioSession.sharedInstance()
            guard !session.isOtherAudioPlaying,
                  session.category == .soloAmbient || session.category == .ambient
            else { return }
            let original = (category: session.category, options: session.categoryOptions, volume: session.outputVolume)
            do {
                try session.setCategory(.ambient, options: .mixWithOthers)
                try session.setActive(true)
            } catch {
                return
            }
            self.view = view
            restore = original
            last = session.outputVolume
            observation = session.observe(\.outputVolume, options: [.new]) { @Sendable [weak self] _, change in
                guard let volume = change.newValue else { return }
                Task { @MainActor in self?.changed(to: volume) }
            }
            if let last, last <= Self.margin || last >= 1 - Self.margin { recentre() }
        }

        func stop() {
            observation?.invalidate()
            observation = nil
            guard let restore else { return }
            self.restore = nil
            setLevel(restore.volume)
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(restore.category, options: restore.options)
        }

        private func changed(to volume: Float) {
            defer { last = volume }
            if let expected, abs(volume - expected) < 0.01 {
                self.expected = nil
                return
            }
            guard let last, volume != last else { return }
            onPress(volume > last ? .volumeUp : .volumeDown)
            if volume <= Self.margin || volume >= 1 - Self.margin { recentre() }
        }

        private func recentre() {
            expected = 0.5
            setLevel(0.5)
        }

        /// The volume view's slider is the one supported way for an app to set the output volume.
        private func setLevel(_ level: Float) {
            guard let slider = view?.subviews.lazy.compactMap({ $0 as? UISlider }).first else { return }
            slider.value = level
        }
    }
}
#endif
