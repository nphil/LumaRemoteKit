#if os(iOS)
import LumaRemoteCore
import SwiftUI
import UIKit

/// Pairs the phone with a TV: by the QR code the TV shows, by a `lumaremote://` link the host passed to
/// `RemoteModel.open(_:)`, or by choosing a TV found on the network and typing its code. TVs are found
/// while the model is active.
public struct PairingView: View {
    private let model: RemoteModel
    private let onPaired: () -> Void

    public init(model: RemoteModel, onPaired: @escaping () -> Void) {
        self.model = model
        self.onPaired = onPaired
    }

    public var body: some View {
        PairingContent(onPaired: onPaired)
            .environment(model)
    }
}

private struct PairingContent: View {
    let onPaired: () -> Void

    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @State private var chosen: TVAdvertisement?
    @State private var code = ""
    @State private var phoneName = ""
    @State private var scanning = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let invite = model.invite {
                    inviteForm(invite)
                } else if let chosen {
                    codeForm(chosen)
                } else {
                    chooser
                }
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.palette.canvas.ignoresSafeArea())
        .navigationTitle("Pair a TV")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $scanning) {
            ScannerSheet { invite in
                model.invite = invite
                scanning = false
            } onCancel: {
                scanning = false
            }
        }
        .onAppear { phoneName = model.settings.phoneName }
        .onChange(of: error) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
    }

    // MARK: Ways to pair

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("On the TV, open Settings › Remote & pointer › Phone remote and choose Pair a phone. Then scan the code it shows, or pick the TV below and type the code.")
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "Scan the code", symbol: "qrcode.viewfinder") { scanning = true }
                .accessibilityIdentifier("pairing.scan")
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("TVs on this network")
                if model.localNetworkDenied {
                    Note("Local Network access is off for this app, so it can't find TVs. Turn it on in Settings › Privacy & Security › Local Network.")
                } else if model.discovered.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Note("Looking for TVs…")
                    }
                } else {
                    ForEach(model.discovered) { tv in
                        DiscoveredRow(tv: tv) {
                            chosen = tv
                            code = ""
                            error = nil
                        }
                    }
                }
            }
        }
    }

    private func inviteForm(_ invite: PairingInvite) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Pair with this TV?")
                .font(theme.font(.title2, weight: .bold))
                .foregroundStyle(theme.palette.ink)
            VStack(alignment: .leading, spacing: 8) {
                Text(invite.code.description)
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.palette.ink)
                    .accessibilityLabel(Text(spokenCode(invite.code.characters)))
                Text("Check that the TV at \(invite.host) shows this code.")
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.radii.surface, style: .continuous).fill(theme.palette.surface))
            PhoneNameField(name: $phoneName)
            ErrorText(error)
            PrimaryButton(title: "Pair", symbol: "link", busy: busy) {
                Task { await attempt { try await model.pair(invite, phoneName: savedName()) } }
            }
            .accessibilityIdentifier("pairing.pair")
            SecondaryButton(title: "Cancel") {
                model.invite = nil
                error = nil
            }
        }
    }

    private func codeForm(_ tv: TVAdvertisement) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Type the code \(tv.name) shows")
                .font(theme.font(.title2, weight: .bold))
                .foregroundStyle(theme.palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !tv.pairingOpen {
                Note("The TV isn't showing a code yet. On the TV, open Settings › Remote & pointer › Phone remote and choose Pair a phone.")
            }
            CodeField(code: $code)
            PhoneNameField(name: $phoneName)
            ErrorText(error)
            PrimaryButton(title: "Pair", symbol: "link", busy: busy) {
                guard let typed = PairingCode(code) else { return }
                Task { await attempt { try await model.pair(tv, code: typed, phoneName: savedName()) } }
            }
            .disabled(PairingCode(code) == nil)
            .accessibilityIdentifier("pairing.pair")
            SecondaryButton(title: "Choose another TV") {
                chosen = nil
                error = nil
            }
        }
    }

    // MARK: Pairing

    private func savedName() -> String {
        let name = phoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings.phoneName = name
        return name
    }

    private func attempt(_ pair: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        let haptics = Haptics(enabled: model.settings.haptics)
        do {
            try await pair()
            haptics.success()
            onPaired()
        } catch {
            haptics.failure()
            self.error = RemoteModel.message(for: error)
        }
    }

    /// Read out one character at a time, so VoiceOver doesn't try to pronounce the code.
    private func spokenCode(_ characters: String) -> String {
        "Code " + characters.map(String.init).joined(separator: " ")
    }
}

// MARK: Pieces

private struct DiscoveredRow: View {
    let tv: TVAdvertisement
    let action: () -> Void

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "tv")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.palette.ink2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tv.name)
                        .font(theme.font(.body, weight: .semibold))
                        .foregroundStyle(theme.palette.ink)
                    Text(detail)
                        .font(theme.font(.footnote))
                        .foregroundStyle(tv.pairingOpen ? theme.palette.positive : theme.palette.ink2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.radii.control, style: .continuous).fill(theme.palette.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tv.isSupported)
        .opacity(tv.isSupported ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if !tv.isSupported { return "Needs a newer version of this app or of LumaTV" }
        return tv.pairingOpen ? "Showing a code" : "Not showing a code yet"
    }
}

/// The TV's eight-character code: upper case, only the characters the TV uses, shown as `XXXX-XXXX`.
private struct CodeField: View {
    @Binding var code: String

    @Environment(\.lumaRemoteTheme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        TextField("XXXX-XXXX", text: $code)
            .font(.system(.title, design: .monospaced).weight(.semibold))
            .foregroundStyle(theme.palette.ink)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.done)
            .focused($focused)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: theme.radii.control, style: .continuous).fill(theme.palette.surface))
            .accessibilityLabel(Text("Code from the TV"))
            .accessibilityIdentifier("pairing.code")
            .onAppear { focused = true }
            .onChange(of: code) { _, typed in
                let formatted = Self.format(typed)
                if formatted != typed { code = formatted }
            }
    }

    static func format(_ typed: String) -> String {
        let characters = typed.uppercased().filter(PairingCode.alphabet.contains).prefix(PairingCode.length)
        guard characters.count > 4 else { return String(characters) }
        return "\(characters.prefix(4))-\(characters.dropFirst(4))"
    }
}

private struct PhoneNameField: View {
    @Binding var name: String

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("This phone's name on the TV")
            TextField(UIDevice.current.name, text: $name)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.ink)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .background(RoundedRectangle(cornerRadius: theme.radii.control, style: .continuous).fill(theme.palette.surface))
                .accessibilityLabel(Text("This phone's name on the TV"))
                .accessibilityIdentifier("pairing.phoneName")
        }
    }
}

private struct ScannerSheet: View {
    let onInvite: (PairingInvite) -> Void
    let onCancel: () -> Void

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        NavigationStack {
            QRScannerView(onInvite: onInvite)
                .navigationTitle("Scan the code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color.black, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                            .font(theme.font(.body, weight: .semibold))
                            .tint(Color.white)
                    }
                }
        }
    }
}

struct SectionTitle: View {
    let text: String

    @Environment(\.lumaRemoteTheme) private var theme

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(theme.font(.footnote, weight: .semibold))
            .foregroundStyle(theme.palette.ink2)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Note: View {
    let text: String

    @Environment(\.lumaRemoteTheme) private var theme

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(theme.font(.subheadline))
            .foregroundStyle(theme.palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ErrorText: View {
    let text: String?

    @Environment(\.lumaRemoteTheme) private var theme

    init(_ text: String?) {
        self.text = text
    }

    var body: some View {
        if let text {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(theme.font(.subheadline, weight: .medium))
            .foregroundStyle(theme.palette.danger)
            .accessibilityIdentifier("pairing.error")
        }
    }
}

/// The screen's main action: a full-width accent capsule.
struct PrimaryButton: View {
    let title: String
    let symbol: String
    var busy = false
    let action: () -> Void

    @Environment(\.lumaRemoteTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().tint(theme.palette.accentInk)
                } else {
                    Image(systemName: symbol).accessibilityHidden(true)
                }
                Text(title)
            }
            .font(theme.font(.body, weight: .semibold))
            .foregroundStyle(theme.palette.accentInk)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(theme.palette.accent))
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        Button(title, action: action)
            .font(theme.font(.body, weight: .semibold))
            .foregroundStyle(theme.palette.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
    }
}
#endif
