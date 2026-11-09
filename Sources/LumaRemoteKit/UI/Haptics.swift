#if os(iOS)
import UIKit

/// Taps under the finger, when the remote's haptics setting is on.
@MainActor
struct Haptics {
    let enabled: Bool

    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let firm = UIImpactFeedbackGenerator(style: .rigid)
    private static let ticks = UISelectionFeedbackGenerator()
    private static let outcomes = UINotificationFeedbackGenerator()

    /// A key going down.
    func press() {
        guard enabled else { return }
        Self.soft.impactOccurred(intensity: 0.7)
    }

    /// A click or a held key taking effect.
    func click() {
        guard enabled else { return }
        Self.firm.impactOccurred(intensity: 0.8)
    }

    /// One arrow of a swipe.
    func tick() {
        guard enabled else { return }
        Self.ticks.selectionChanged()
    }

    func success() {
        guard enabled else { return }
        Self.outcomes.notificationOccurred(.success)
    }

    func failure() {
        guard enabled else { return }
        Self.outcomes.notificationOccurred(.error)
    }
}
#endif
