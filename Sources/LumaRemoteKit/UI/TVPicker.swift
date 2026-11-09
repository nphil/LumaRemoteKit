#if os(iOS)
import LumaRemoteCore
import SwiftUI

/// The paired TVs: choose the one the remote controls, forget one, or pair another.
public struct TVPicker: View {
    private let model: RemoteModel

    public init(model: RemoteModel) {
        self.model = model
    }

    public var body: some View {
        TVList()
            .environment(model)
    }
}

private struct TVList: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting: PairedTV?

    var body: some View {
        List {
            if !model.tvs.isEmpty {
                Section {
                    ForEach(model.tvs) { tv in
                        Button {
                            model.select(tv)
                            dismiss()
                        } label: {
                            row(tv)
                        }
                        .swipeActions {
                            Button("Forget", systemImage: "trash") { forgetting = tv }
                                .tint(theme.palette.danger)
                        }
                        .contextMenu {
                            Button("Forget", systemImage: "trash", role: .destructive) { forgetting = tv }
                        }
                        .accessibilityAction(named: Text("Forget")) { forgetting = tv }
                        .remoteRow(theme)
                    }
                } header: {
                    SectionTitle("Paired TVs")
                }
            }
            Section {
                NavigationLink {
                    PairingView(model: model) { dismiss() }
                } label: {
                    Label("Pair a TV", systemImage: "plus")
                        .foregroundStyle(theme.palette.accent)
                }
                .accessibilityIdentifier("tvs.pair")
                .remoteRow(theme)
            }
        }
        .remoteList(theme)
        .navigationTitle("TVs")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            forgetting.map { "Forget \($0.name)?" } ?? "",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible,
            presenting: forgetting
        ) { tv in
            Button("Forget", role: .destructive) { model.forget(tv) }
        } message: { _ in
            Text("This phone stops controlling it. The TV keeps listing the phone until it's removed there, in Settings › Remote & pointer › Phone remote.")
        }
    }

    private func row(_ tv: PairedTV) -> some View {
        let current = model.current?.id == tv.id
        return HStack(spacing: 14) {
            Image(systemName: "tv")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.palette.ink2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tv.name)
                    .font(theme.font(.body, weight: .semibold))
                    .foregroundStyle(theme.palette.ink)
                Text(current ? model.statusText : tv.host)
                    .font(theme.font(.footnote))
                    .foregroundStyle(theme.palette.ink2)
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.palette.accent)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
#endif
