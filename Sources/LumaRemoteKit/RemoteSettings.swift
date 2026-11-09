import Foundation
import Observation

/// The remote's own preferences, in the kit's defaults suite rather than the host's.
@MainActor
@Observable
public final class RemoteSettings {
    public enum PointerMode: String, CaseIterable, Sendable {
        /// The pointer moves while a thumb rests on the pad.
        case holdToPoint
        /// The pointer follows the phone while the Pointer tab is open.
        case alwaysOn
    }

    public static let suiteName = "com.nphil.lumaremote"

    @ObservationIgnored private let defaults: UserDefaults

    /// What the TV lists this phone as; iOS gives apps only the model's name.
    public var phoneName: String { didSet { defaults.set(phoneName, forKey: "phoneName") } }
    public var pointerMode: PointerMode { didSet { defaults.set(pointerMode.rawValue, forKey: "pointerMode") } }
    /// 0.5–2, scaling the air mouse's gain.
    public var pointerSpeed: Double { didSet { defaults.set(pointerSpeed, forKey: "pointerSpeed") } }
    /// 0.5–2, scaling touchpad motion.
    public var touchpadSpeed: Double { didSet { defaults.set(touchpadSpeed, forKey: "touchpadSpeed") } }
    public var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    /// The phone's volume buttons change the TV's volume while the remote is open.
    public var volumeButtons: Bool { didSet { defaults.set(volumeButtons, forKey: "volumeButtons") } }
    /// The TV the remote opened last.
    public var lastTV: String? { didSet { defaults.set(lastTV, forKey: "lastTV") } }

    public init(defaults: UserDefaults = UserDefaults(suiteName: RemoteSettings.suiteName) ?? .standard) {
        self.defaults = defaults
        phoneName = defaults.string(forKey: "phoneName") ?? ""
        pointerMode = defaults.string(forKey: "pointerMode").flatMap(PointerMode.init) ?? .holdToPoint
        pointerSpeed = defaults.object(forKey: "pointerSpeed") as? Double ?? 1
        touchpadSpeed = defaults.object(forKey: "touchpadSpeed") as? Double ?? 1
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        volumeButtons = defaults.object(forKey: "volumeButtons") as? Bool ?? true
        lastTV = defaults.string(forKey: "lastTV")
    }
}
