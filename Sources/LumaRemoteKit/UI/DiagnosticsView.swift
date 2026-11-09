#if os(iOS)
import LumaRemoteCore
import SwiftUI
import UIKit

/// What the remote knows about the session, the TV's state and the pointer channel, with a latency
/// measurement over both channels and a copy of it all as text.
public struct DiagnosticsView: View {
    private let model: RemoteModel

    public init(model: RemoteModel) {
        self.model = model
    }

    public var body: some View {
        DiagnosticsList()
            .environment(model)
    }
}

private struct DiagnosticsList: View {
    struct Item: Identifiable {
        let label: String
        let value: String
        var id: String { label }

        init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme
    @State private var latency: RemoteModel.Latency?
    @State private var measuring = false
    @State private var copied = false

    var body: some View {
        List {
            Section {
                ForEach(connectionRows) { ValueRow($0.label, $0.value).remoteRow(theme) }
            } header: {
                SectionTitle("Connection")
            }
            Section {
                ForEach(tvRows) { ValueRow($0.label, $0.value).remoteRow(theme) }
            } header: {
                SectionTitle("TV")
            }
            Section {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let rows = pointerRows(model.pointer.report)
                    VStack(spacing: 10) {
                        ForEach(rows) { ValueRow($0.label, $0.value) }
                    }
                }
                .remoteRow(theme)
            } header: {
                SectionTitle("Pointer")
            }
            Section {
                if let latency {
                    ForEach(latencyRows(latency)) { ValueRow($0.label, $0.value).remoteRow(theme) }
                }
                Button {
                    Task { await measure() }
                } label: {
                    HStack(spacing: 10) {
                        if measuring { ProgressView() }
                        Text(measuring ? "Measuring…" : "Measure 20 round trips")
                    }
                }
                .disabled(measuring || model.connection != .connected)
                .accessibilityIdentifier("diagnostics.measure")
                .remoteRow(theme)
            } header: {
                SectionTitle("Latency")
            } footer: {
                Text("Round trips from the phone to the TV and back, over the encrypted session and over the pointer channel.")
                    .font(theme.font(.footnote))
                    .foregroundStyle(theme.palette.ink2)
            }
            Section {
                Button(copied ? "Copied" : "Copy as text", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = report
                    copied = true
                }
                .remoteRow(theme)
            }
        }
        .remoteList(theme)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func measure() async {
        measuring = true
        latency = await model.measureLatency(samples: 20)
        measuring = false
    }

    // MARK: Rows

    private var connectionRows: [Item] {
        var rows = [Item("State", model.statusText)]
        if let tv = model.current {
            rows += [
                Item("TV", tv.name),
                Item("Address", "\(tv.host):\(tv.port)"),
                Item("Bonjour", tv.service ?? "None"),
                Item("TV id", tv.id.description),
                Item("Phone id", tv.device),
                Item("Paired", tv.pairedAt.formatted(date: .abbreviated, time: .shortened)),
            ]
        }
        if let detail = model.incompatibility { rows.append(Item("Decode error", detail)) }
        if model.localNetworkDenied { rows.append(Item("Local Network", "Refused")) }
        rows.append(Item("Kit", LumaRemote.version))
        return rows
    }

    private var tvRows: [Item] {
        let state = model.state
        let ime = state.ime
        var field = "None"
        if ime.active {
            var parts = ["\(ime.purposeKind)", "enter \(ime.enterKind)"]
            if let max = ime.max, max > 0 { parts.append("up to \(max)") }
            if ime.hiddenText { parts.append("hidden") }
            if ime.sensitive { parts.append("sensitive") }
            field = parts.joined(separator: ", ")
        }
        var volume = "Unknown"
        if let level = state.volume?.level {
            volume = VolumeState.format(level)
            if let max = state.volume?.max { volume += " of \(VolumeState.format(max))" }
            if state.volume?.muted == true { volume += ", muted" }
            if let via = state.volume?.via { volume += " (\(via))" }
        }
        return [
            Item("Power", state.power == .standby ? "Standby" : "On"),
            Item("In front", state.foreground.isEmpty ? "LumaTV" : state.foreground),
            Item("Text field", field),
            Item("Volume", volume),
            Item("Actions", state.actions.isEmpty ? "None" : state.actions.sorted().joined(separator: ", ")),
        ]
    }

    private func pointerRows(_ report: PointerReport) -> [Item] {
        [
            Item("Motion", "\(report.x), \(report.y)"),
            Item("Scroll", "\(report.scrollX), \(report.scrollY)"),
            Item("Clicks", "\(report.leftPresses) left, \(report.rightPresses) right"),
            Item("Centred", "\(report.centres)"),
        ]
    }

    private func latencyRows(_ latency: RemoteModel.Latency) -> [Item] {
        [Item("Session", Self.describe(latency.session)), Item("Pointer channel", Self.describe(latency.datagram))]
    }

    private static func describe(_ summary: LatencySummary?) -> String {
        guard let summary else { return "No answer" }
        return "median \(milliseconds(summary.median)), 95% \(milliseconds(summary.p95)), worst \(milliseconds(summary.worst)) (\(summary.count))"
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let value = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        return value.formatted(.number.precision(.fractionLength(1))) + " ms"
    }

    private var report: String {
        let pointer = pointerRows(model.pointer.report)
        let sections: [(title: String, rows: [Item])] = [
            ("Connection", connectionRows),
            ("TV", tvRows),
            ("Pointer", pointer),
            ("Latency", latency.map(latencyRows) ?? [Item("Latency", "Not measured")]),
        ]
        return sections.map { section in
            ([section.title] + section.rows.map { "  \($0.label): \($0.value)" }).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
#endif
