#if os(iOS)
import LumaRemoteCore
import SwiftUI

/// Everything that isn't on the remote's face, one tap away: the rest of the TV remote's keys, apps,
/// LumaTV's own actions while the TV offers them, and the remote's settings and diagnostics. What opens
/// something on the TV closes the sheet, so the pad is under the thumb again.
struct MoreSheet: View {
    let onDone: () -> Void

    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme

    private var ready: Bool { model.connection == .connected && model.state.power == .on }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Group {
                    TileSection("Playback") {
                        KeyTile(.play, symbol: "play.fill", label: "Play")
                        KeyTile(.pause, symbol: "pause.fill", label: "Pause")
                        KeyTile(.stop, symbol: "stop.fill", label: "Stop")
                    }
                    TileSection("TV") {
                        KeyTile(.info, symbol: "info.circle", label: "Info")
                        KeyTile(.more, symbol: "ellipsis.circle", label: "More actions")
                        KeyTile(.exit, symbol: "rectangle.portrait.and.arrow.right", label: "Exit")
                        ActionTile(symbol: "gearshape.2", label: "All settings") {
                            if model.state.allows(.settings(page: nil)) {
                                await run(.settings(page: nil))
                            } else if model.send(.key(.menu, .hold)) {
                                onDone()
                            }
                        }
                    }
                    TileSection("Colour keys") {
                        ColourKey(key: .red, colour: .red, label: "Red")
                        ColourKey(key: .green, colour: .green, label: "Green")
                        ColourKey(key: .yellow, colour: .yellow, label: "Yellow")
                        ColourKey(key: .blue, colour: .blue, label: "Blue")
                    }
                    TileSection("Apps") {
                        KeyTile(.netflix, symbol: "n.square", label: "Netflix")
                        KeyTile(.amazon, symbol: "a.square", label: "Prime Video")
                        if model.state.allows(.launch(app: .string(""))) {
                            ListTile(symbol: "square.grid.2x2", label: "All apps") {
                                ItemList(kind: .apps, title: "Apps", onDone: onDone) { .launch(app: $0) }
                            }
                        }
                    }
                    if hasLumaTVActions {
                        lumaTV
                    }
                }
                .disabled(!ready)
                TileSection("Remote") {
                    ListTile(symbol: "iphone", label: "Settings") {
                        RemoteSettingsView(model: model)
                    }
                    ListTile(symbol: "stethoscope", label: "Diagnostics") {
                        DiagnosticsView(model: model)
                    }
                }
            }
            .padding(16)
        }
        .background(theme.palette.canvas.ignoresSafeArea())
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let lumaTVActions: [TVAction] = [
        .quickSettings, .settings(page: nil), .notifications, .inputPicker, .pictureOff, .cameras, .closeCamera,
        .camera(.string("")), .tune(channel: .string("")), .volume(level: 0),
    ]

    private var hasLumaTVActions: Bool {
        Self.lumaTVActions.contains(where: model.state.allows)
    }

    /// LumaTV's own actions. Home, the guide and power are the remote's keys on the face.
    private var lumaTV: some View {
        let state = model.state
        return TileSection("LumaTV") {
            if state.allows(.quickSettings) {
                ActionTile(symbol: "slider.horizontal.3", label: "Quick Settings") { await run(.quickSettings) }
            }
            if state.allows(.settings(page: nil)) {
                ActionTile(symbol: "gearshape", label: "Settings") { await run(.settings(page: nil)) }
            }
            if state.allows(.notifications) {
                ActionTile(symbol: "bell", label: "Notifications") { await run(.notifications) }
            }
            if state.allows(.inputPicker) {
                ActionTile(symbol: "rectangle.on.rectangle", label: "Inputs") { await run(.inputPicker) }
            }
            if state.allows(.tune(channel: .string(""))) {
                ListTile(symbol: "list.number", label: "Channels") {
                    ItemList(kind: .channels, title: "Channels", onDone: onDone) { .tune(channel: $0) }
                }
            }
            if state.allows(.cameras) {
                ActionTile(symbol: "video", label: "Cameras") { await run(.cameras) }
            }
            if state.allows(.camera(.string(""))) {
                ListTile(symbol: "list.bullet.rectangle", label: "One camera") {
                    ItemList(kind: .cameras, title: "Cameras", onDone: onDone) { .camera($0) }
                }
            }
            if state.allows(.closeCamera) {
                ActionTile(symbol: "video.slash", label: "Close camera") { await model.perform(.closeCamera) }
            }
            if state.allows(.pictureOff) {
                ActionTile(symbol: "eye.slash", label: "Picture off") { await model.perform(.pictureOff) }
            }
        } footer: {
            if state.allows(.volume(level: 0)) {
                ReceiverVolume()
            }
        }
    }

    /// Runs an action that opens something on the TV, closing the sheet once the TV has done it.
    private func run(_ action: TVAction) async {
        if await model.perform(action) { onDone() }
    }
}

// MARK: Sections and tiles

/// A titled plate of tiles, with room below for a control that needs the full width.
private struct TileSection<Tiles: View, Footer: View>: View {
    let title: String
    @ViewBuilder let tiles: Tiles
    @ViewBuilder let footer: Footer

    @Environment(\.lumaRemoteTheme) private var theme
    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 76

    init(_ title: String, @ViewBuilder tiles: () -> Tiles, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.tiles = tiles()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title)
                .padding(.leading, 4)
            VStack(spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 8, alignment: .top)], spacing: 16) {
                    tiles
                }
                footer
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: theme.radii.surface, style: .continuous).fill(theme.palette.surface))
        }
    }
}

extension TileSection where Footer == EmptyView {
    init(_ title: String, @ViewBuilder tiles: () -> Tiles) {
        self.init(title, tiles: tiles, footer: { EmptyView() })
    }
}

/// A key above its name. The name is for sighted people scanning the sheet; VoiceOver reads the key's label.
private struct Tile<Key: View>: View {
    let label: String
    @ViewBuilder let key: Key

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            key
            Text(label)
                .font(theme.font(.caption, weight: .medium))
                .foregroundStyle(theme.palette.ink2)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct KeyTile: View {
    let spec: KeySpec

    init(_ key: RemoteKey, symbol: String, label: String) {
        spec = KeySpec(key: key, symbol: symbol, label: label)
    }

    var body: some View {
        Tile(label: spec.label) { RemoteKeyButton(spec) }
    }
}

private struct ActionTile: View {
    let symbol: String
    let label: String
    let action: () async -> Void

    @State private var running = false

    var body: some View {
        Tile(label: label) {
            GlyphButton(symbol: symbol, label: label) {
                guard !running else { return }
                running = true
                Task {
                    await action()
                    running = false
                }
            }
        }
    }
}

private struct ListTile<Destination: View>: View {
    let symbol: String
    let label: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        Tile(label: label) {
            NavigationLink(destination: destination) {
                Image(systemName: symbol)
            }
            .buttonStyle(KeyButtonStyle())
            .accessibilityLabel(Text(label))
        }
    }
}

/// The TV remote's red, green, yellow and blue keys keep their colours on every theme.
private struct ColourKey: View {
    let key: RemoteKey
    let colour: Color
    let label: String

    @Environment(RemoteModel.self) private var model
    @State private var pressed = false

    var body: some View {
        Tile(label: label) {
            Image(systemName: "circle.fill")
                .foregroundStyle(colour)
                .modifier(KeyDisc(style: .raised, pressed: pressed))
                .modifier(KeyPressGesture(key: key, pressed: $pressed))
                .keyAccessibility(label, symbol: "circle.fill") { model.tap(key) }
                .accessibilityIdentifier("remote.key.\(key.rawValue)")
        }
    }
}

// MARK: Lists and the receiver

/// One of the TV's lists; choosing an item runs its action and closes the sheet.
private struct ItemList: View {
    let kind: ListKind
    let title: String
    let onDone: () -> Void
    let action: (ItemID) -> TVAction

    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @State private var items: [ListItem]?
    @State private var failed = false
    @State private var query = ""

    var body: some View {
        List {
            if let items {
                ForEach(filtered(items)) { item in
                    Button {
                        let target = action(item.id)
                        Task {
                            if await model.perform(target) { onDone() }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if let number = item.no {
                                Text(number)
                                    .monospacedDigit()
                                    .foregroundStyle(theme.palette.ink2)
                            }
                            Text(item.label)
                                .foregroundStyle(theme.palette.ink)
                        }
                        .frame(minHeight: 44)
                    }
                    .remoteRow(theme)
                }
            } else if failed {
                Text("Couldn't get the list from the TV.")
                    .foregroundStyle(theme.palette.ink2)
                    .remoteRow(theme)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .remoteRow(theme)
            }
        }
        .remoteList(theme)
        .searchable(text: $query)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let list = await model.list(kind) { items = list } else { failed = true }
        }
    }

    private func filtered(_ items: [ListItem]) -> [ListItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.label.localizedCaseInsensitiveContains(query) || $0.no == query }
    }
}

/// The AV receiver's level, set when the finger lifts; the volume keys still step it.
private struct ReceiverVolume: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @State private var level: Double = 0
    @State private var editing = false

    var body: some View {
        let volume = model.state.volume
        let maximum = Double(max(volume?.max ?? 100, 1))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Receiver volume", systemImage: "hifispeaker")
                Spacer()
                Text("\(Int(level))")
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.ink2)
            }
            .font(theme.font(.subheadline, weight: .medium))
            .foregroundStyle(theme.palette.ink)
            Slider(value: $level, in: 0...maximum, step: 1) {
                Text("Receiver volume")
            } onEditingChanged: { editing in
                self.editing = editing
                if !editing {
                    let target = Int(level)
                    Task { await model.perform(.volume(level: target)) }
                }
            }
        }
        .onAppear { level = Double(volume?.level ?? 0) }
        .onChange(of: volume?.level) { _, new in
            if !editing, let new { level = Double(new) }
        }
    }
}
#endif
