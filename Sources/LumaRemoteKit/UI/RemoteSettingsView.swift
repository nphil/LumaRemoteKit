#if os(iOS)
import LumaRemoteCore
import SwiftUI
import UIKit

/// The remote's own settings: the phone's name, the air mouse, the touchpad, haptics and the volume buttons.
public struct RemoteSettingsView: View {
    private let model: RemoteModel

    public init(model: RemoteModel) {
        self.model = model
    }

    public var body: some View {
        SettingsForm(settings: model.settings)
    }
}

private struct SettingsForm: View {
    @Bindable var settings: RemoteSettings

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        Form {
            Section {
                TextField(UIDevice.current.name, text: $settings.phoneName)
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel(Text("Phone name"))
                    .remoteRow(theme)
            } header: {
                SectionTitle("Phone name")
            } footer: {
                footer("What the TV calls this phone. It takes effect the next time the phone pairs.")
            }
            Section {
                Picker("Pointer", selection: $settings.pointerMode) {
                    Text("While a thumb is on the pad").tag(RemoteSettings.PointerMode.holdToPoint)
                    Text("Whenever the pad is open").tag(RemoteSettings.PointerMode.alwaysOn)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .remoteRow(theme)
                SpeedSlider(title: "Pointer speed", value: $settings.pointerSpeed)
                    .remoteRow(theme)
            } header: {
                SectionTitle("Air mouse")
            } footer: {
                footer("The pointer follows the phone as it tilts and turns.")
            }
            Section {
                SpeedSlider(title: "Touchpad speed", value: $settings.touchpadSpeed)
                    .remoteRow(theme)
            } header: {
                SectionTitle("Touchpad")
            }
            Section {
                Toggle("Haptics", isOn: $settings.haptics)
                    .remoteRow(theme)
                Toggle("Volume buttons change the TV's volume", isOn: $settings.volumeButtons)
                    .remoteRow(theme)
            } footer: {
                footer("The phone's volume buttons work for the TV while the remote is open and the phone isn't playing sound.")
            }
        }
        .remoteList(theme)
        .navigationTitle("Remote settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.footnote))
            .foregroundStyle(theme.palette.ink2)
    }
}

/// 0.5× to 2×, in steps of a tenth.
private struct SpeedSlider: View {
    let title: String
    @Binding var value: Double

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(1))) + "×")
                    .foregroundStyle(theme.palette.ink2)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0.5...2, step: 0.1) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: "tortoise").accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "hare").accessibilityHidden(true)
            }
            .foregroundStyle(theme.palette.ink2)
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
