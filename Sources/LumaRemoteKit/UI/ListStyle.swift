#if os(iOS)
import SwiftUI

extension View {
    /// A list or form in the remote's theme: the canvas behind, rows on the surface colour.
    func remoteList(_ theme: RemoteTheme) -> some View {
        scrollContentBackground(.hidden)
            .background(theme.palette.canvas.ignoresSafeArea())
            .font(theme.font(.body))
            .foregroundStyle(theme.palette.ink)
            .tint(theme.palette.accent)
    }

    func remoteRow(_ theme: RemoteTheme) -> some View {
        listRowBackground(theme.palette.surface)
            .listRowSeparatorTint(theme.palette.edge)
    }
}

/// A label and its value on one row, wrapping under each other at large text sizes.
struct ValueRow: View {
    let label: String
    let value: String

    @Environment(\.lumaRemoteTheme) private var theme

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).foregroundStyle(theme.palette.ink)
                Spacer(minLength: 12)
                Text(value).foregroundStyle(theme.palette.ink2).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).foregroundStyle(theme.palette.ink)
                Text(value).foregroundStyle(theme.palette.ink2)
            }
        }
        .font(theme.font(.body))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}
#endif
