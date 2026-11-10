#if os(iOS)
import LumaRemoteCore
import SwiftUI

/// The phone remote. Along the top: close, the TV and its state, power. In the middle a pad: the
/// D-pad, the touchpad or the air mouse. Beneath it the keys used every day, laid out like the TV's own
/// remote; everything else is one tap away under More. Styled by the host's `lumaRemoteTheme`.
public struct LumaRemoteView: View {
    private let model: RemoteModel
    private let onClose: () -> Void
    private let managesLifecycle: Bool

    public init(model: RemoteModel, managesLifecycle: Bool = true, onClose: @escaping () -> Void) {
        self.model = model
        self.managesLifecycle = managesLifecycle
        self.onClose = onClose
    }

    public var body: some View {
        RemoteScreen(onClose: onClose, managesLifecycle: managesLifecycle)
            .environment(model)
    }
}

enum PadMode: String, CaseIterable {
    case keys, touchpad, pointer

    var symbol: String {
        switch self {
        case .keys: "dpad"
        case .touchpad: "hand.draw"
        case .pointer: "hand.point.up.left"
        }
    }

    var label: String {
        switch self {
        case .keys: "Navigation pad"
        case .touchpad: "Touchpad"
        case .pointer: "Air mouse"
        }
    }
}

enum RemoteSheet: String, Identifiable {
    case tvs, more, pairing
    var id: String { rawValue }
}

private struct RemoteScreen: View {
    let onClose: () -> Void
    let managesLifecycle: Bool

    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("padMode", store: UserDefaults(suiteName: RemoteSettings.suiteName)) private var mode = PadMode.keys
    @State private var sheet: RemoteSheet?
    @State private var keyboard = false
    @State private var keyboardFollowsTV = false

    /// Keys reach the TV only while a session is open and the screen is on; Power works regardless.
    private var ready: Bool { model.connection == .connected && model.state.power == .on }

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.palette.canvas.ignoresSafeArea()
            VStack(spacing: 16) {
                TopBar(onClose: onClose) { sheet = .tvs }
                StatusBanner { sheet = .pairing }
                // A link the host opened asks to pair here rather than in a sheet: a sheet presented while
                // the host's full-screen cover is still sliding in takes the cover with it when it closes.
                if model.invite != nil {
                    PairingView(model: model) {}
                } else if model.current == nil {
                    NoTV { sheet = .pairing }
                } else {
                    ModePicker(mode: $mode)
                    pad
                        .frame(maxWidth: 340, maxHeight: 340)
                        .frame(maxHeight: .infinity)
                        .disabled(!ready)
                    KeyCluster { showKeyboard(!keyboard, followingTV: false) }
                        .disabled(!ready)
                    GlyphButton(symbol: "ellipsis", label: "More") { sheet = .more }
                        .accessibilityIdentifier("remote.more")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .ignoresSafeArea(.keyboard)

            NoticeToast()
                .padding(.bottom, keyboard ? 96 : 84)
            if keyboard, ready {
                KeyboardPanel { showKeyboard(false, followingTV: false) }
                    .transition(.move(edge: .bottom))
            }
        }
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.palette.accent)
        .background {
            if model.settings.volumeButtons, model.connection == .connected {
                VolumeButtonCatcher { model.volumeButton($0) }
                    .frame(width: 1, height: 1)
            }
        }
        .sheet(item: $sheet) { sheet in
            SheetContainer(sheet: sheet) { self.sheet = $0 }
        }
        .onAppear { if managesLifecycle { model.activate() } }
        .onDisappear { if managesLifecycle { model.deactivate() } }
        .onChange(of: scenePhase) { _, phase in
            guard managesLifecycle else { return }
            switch phase {
            case .active: model.activate()
            case .background: model.deactivate()
            default: break
            }
        }
        // The TV opening a text field brings the keyboard up; closing it takes away only a keyboard it brought.
        .onChange(of: model.state.ime.active) { _, active in
            if active, !keyboard { showKeyboard(true, followingTV: true) }
            if !active, keyboardFollowsTV { showKeyboard(false, followingTV: false) }
        }
    }

    @ViewBuilder
    private var pad: some View {
        switch mode {
        case .keys: DPadView()
        case .touchpad: TouchpadView()
        case .pointer: PointerPadView()
        }
    }

    private func showKeyboard(_ shown: Bool, followingTV: Bool) {
        keyboardFollowsTV = shown && followingTV
        keyboard = shown
    }
}

/// Close, the TV's name and state (which opens the TV list), and power.
private struct TopBar: View {
    let onClose: () -> Void
    let onPickTV: () -> Void

    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        HStack(spacing: KeyMetrics.gap) {
            GlyphButton(symbol: "xmark", label: "Close remote", action: onClose)
                .accessibilityIdentifier("remote.close")
            Button(action: onPickTV) {
                VStack(spacing: 2) {
                    Text(model.current?.name ?? "No TV")
                        .font(theme.font(.headline, weight: .semibold))
                        .foregroundStyle(theme.palette.ink)
                    HStack(spacing: 6) {
                        Circle().fill(statusColour).frame(width: 8, height: 8)
                        Text(model.statusText)
                            .font(theme.font(.caption, weight: .medium))
                            .foregroundStyle(theme.palette.ink2)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: KeyMetrics.size)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Choose a TV"))
            .accessibilityIdentifier("remote.tvpicker")
            GlyphButton(symbol: "power", label: model.connection == .connected ? "Power" : "Wake the TV") { model.power() }
                .disabled(model.current == nil)
                .accessibilityIdentifier("remote.power")
        }
    }

    private var statusColour: Color {
        let palette = theme.palette
        switch model.connection {
        case .none, .offline: return palette.ink3
        case .incompatible: return palette.danger
        case .connecting: return palette.warning
        case .connected: return model.state.power == .standby ? palette.warning : palette.positive
        case .unpaired: return palette.danger
        }
    }
}

extension RemoteModel {
    /// The session's state in a few words.
    var statusText: String {
        switch connection {
        case .none: "No TV chosen"
        case .connecting: "Connecting"
        case .connected: state.power == .standby ? "Standby" : "Connected"
        case .offline: "Off or out of reach"
        case .incompatible: "The TV answered in a way this app doesn't understand. Update Marquee or LumaTV."
        case .unpaired: "Needs pairing"
        }
    }
}

/// Why the keys are dimmed, and the one thing that fixes it.
private struct StatusBanner: View {
    let onPair: () -> Void

    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let content {
            HStack(spacing: KeyMetrics.gap) {
                Text(content.text)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(content.action, action: content.perform)
                    .font(theme.font(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.palette.accentInk)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(theme.palette.accent))
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: theme.radii.control, style: .continuous).fill(theme.palette.surface))
            .accessibilityElement(children: .contain)
        }
    }

    private var content: (text: String, action: String, perform: () -> Void)? {
        let name = model.current?.name ?? "The TV"
        if model.localNetworkDenied {
            return ("Local Network access is off for this app, so it can't reach the TV.", "Settings", {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            })
        }
        switch model.connection {
        case .offline: return ("\(name) is off or out of reach.", "Wake", { model.wake() })
        case .incompatible: return ("\(name) answered in a way this app doesn't understand. Update Marquee or LumaTV.", "Retry", { model.wake() })
        case .unpaired: return ("\(name) no longer knows this phone.", "Pair again", onPair)
        case .connected where model.state.power == .standby: return ("\(name) is in standby.", "Turn on", { model.power() })
        default: return nil
        }
    }
}

/// No TV paired yet.
private struct NoTV: View {
    let onPair: () -> Void

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "tv")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(theme.palette.ink3)
                .accessibilityHidden(true)
            Text("Pair this phone with a LumaTV to use it as the remote.")
                .font(theme.font(.title3, weight: .semibold))
                .foregroundStyle(theme.palette.ink)
                .multilineTextAlignment(.center)
            Button("Pair a TV", action: onPair)
                .font(theme.font(.body, weight: .semibold))
                .foregroundStyle(theme.palette.accentInk)
                .padding(.horizontal, 28)
                .frame(minHeight: 50)
                .background(Capsule().fill(theme.palette.accent))
                .accessibilityIdentifier("remote.pair")
            Spacer()
        }
        .padding(24)
    }
}

/// Which pad fills the middle: three glyph keys on one plate.
private struct ModePicker: View {
    @Binding var mode: PadMode

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        HStack(spacing: KeyMetrics.gap) {
            ForEach(PadMode.allCases, id: \.self) { option in
                Button {
                    mode = option
                } label: {
                    Image(systemName: option.symbol)
                }
                .buttonStyle(KeyButtonStyle(style: mode == option ? .raised : .onPlate))
                .accessibilityLabel(Text(option.label))
                .accessibilityAddTraits(mode == option ? .isSelected : [])
                .accessibilityIdentifier("remote.mode.\(option.rawValue)")
            }
        }
        .background(Capsule().fill(theme.palette.surface))
        .overlay(Capsule().strokeBorder(theme.palette.edge, lineWidth: 0.5))
    }
}

/// The everyday keys: volume and channel rockers either side of Back, Home, settings, the media keys,
/// input, the guide and the keyboard.
private struct KeyCluster: View {
    let onKeyboard: () -> Void

    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: KeyMetrics.gap) {
            Rocker(
                top: KeySpec(key: .volumeUp, symbol: "plus", label: "Volume up"),
                middle: KeySpec(key: .mute, symbol: model.state.volume?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Mute"),
                bottom: KeySpec(key: .volumeDown, symbol: "minus", label: "Volume down")
            )
            Grid(horizontalSpacing: KeyMetrics.gap, verticalSpacing: KeyMetrics.gap) {
                GridRow {
                    RemoteKeyButton(KeySpec(key: .back, symbol: "arrow.uturn.backward", label: "Back"))
                    RemoteKeyButton(KeySpec(key: .home, symbol: "house", label: "Home"))
                    RemoteKeyButton(KeySpec(key: .menu, symbol: "gearshape", label: "Settings"))
                }
                GridRow {
                    RemoteKeyButton(KeySpec(key: .rewind, symbol: "backward.fill", label: "Rewind"))
                    RemoteKeyButton(KeySpec(key: .playPause, symbol: "playpause.fill", label: "Play or pause"),
                                    style: model.state.isMarqueeInFront ? .accent : .raised)
                    RemoteKeyButton(KeySpec(key: .fastForward, symbol: "forward.fill", label: "Fast forward"))
                }
                GridRow {
                    RemoteKeyButton(KeySpec(key: .input, symbol: "cable.connector.horizontal", label: "Input"))
                    RemoteKeyButton(KeySpec(key: .guide, symbol: "tablecells", label: "Guide"))
                    GlyphButton(symbol: "keyboard", label: "Keyboard", action: onKeyboard)
                        .accessibilityIdentifier("remote.keyboard")
                }
            }
            Rocker(
                top: KeySpec(key: .channelUp, symbol: "chevron.up", label: "Channel up"),
                middle: KeySpec(key: .list, symbol: "list.bullet", label: "Channel list"),
                bottom: KeySpec(key: .channelDown, symbol: "chevron.down", label: "Channel down")
            )
        }
    }
}

/// The model's latest notice, for three seconds, and read out by VoiceOver.
private struct NoticeToast: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        if let notice = model.notice {
            Text(notice.text)
                .font(theme.font(.subheadline, weight: .medium))
                .foregroundStyle(theme.palette.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Capsule().fill(theme.palette.surfaceRaised))
                .overlay(Capsule().strokeBorder(theme.palette.edge, lineWidth: 0.5))
                .padding(.horizontal, 24)
                .onTapGesture { model.dismissNotice() }
                .task(id: notice.id) {
                    AccessibilityNotification.Announcement(notice.text).post()
                    try? await Task.sleep(for: .seconds(3))
                    if model.notice?.id == notice.id { model.dismissNotice() }
                }
                .accessibilityIdentifier("remote.notice")
        }
    }
}

/// A sheet over the remote, in the remote's theme.
private struct SheetContainer: View {
    let sheet: RemoteSheet
    let show: (RemoteSheet?) -> Void

    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                switch sheet {
                case .tvs: TVPicker(model: model)
                case .more: MoreSheet { show(nil) }
                case .pairing: PairingView(model: model) { show(nil) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { show(nil) }
                        .font(theme.font(.body, weight: .semibold))
                }
            }
        }
        .tint(theme.palette.accent)
        .preferredColorScheme(theme.colorScheme)
        .presentationBackground(theme.palette.canvas)
        .presentationDetents(sheet == .more ? [.medium, .large] : [.large])
    }
}
#endif
