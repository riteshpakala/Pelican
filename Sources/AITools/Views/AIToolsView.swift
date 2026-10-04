import PelicanKit
import PelicanUI
import SwiftUI

package struct AIToolsView: View {
    let store: AIToolsStore
    let host: MonitorHost

    package init(store: AIToolsStore, host: MonitorHost) {
        self.store = store
        self.host = host
    }

    package var body: some View {
        // The store is an ObservableObject; observe it in a child view.
        AIToolsContent(store: store, host: host)
    }
}

private struct AIToolsContent: View {
    @ObservedObject var store: AIToolsStore
    let host: MonitorHost
    /// nil = every tool.
    @State private var selected: String?

    private var tool: AITool? { selected.flatMap { id in store.catalog.first { $0.id == id } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader("AI Tools",
                             "what the AI tools on this Mac send, and which one sent it")
                selector
                SummaryCard(store: store, tool: tool, host: host)
                if let tool, tool.awaitingFingerprint {
                    AwaitingFingerprintCard(tool: tool)
                } else {
                    SurfacesCard(store: store, tool: tool)
                    EndpointsCard(store: store, tool: tool)
                    ActivityCard(store: store, tool: tool)
                }
            }
            .padding(24)
        }
    }

    private var selector: some View {
        HStack(spacing: 8) {
            SelectorChip("All", selected: selected == nil) { selected = nil }
            ForEach(store.catalog) { entry in
                SelectorChip(entry.name,
                             tag: tag(for: entry),
                             selected: selected == entry.id) { selected = entry.id }
            }
        }
    }

    private func tag(for tool: AITool) -> String? {
        if store.running[tool.id]?.isEmpty == false { return "running" }
        if tool.awaitingFingerprint { return "not yet seen" }
        return nil
    }
}

// MARK: - Summary

private struct SummaryCard: View {
    @ObservedObject var store: AIToolsStore
    let tool: AITool?
    let host: MonitorHost

    var body: some View {
        let totals = store.day.bytesOut(forTool: tool?.id)
        PelicanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(tool?.name ?? "Every tool")
                        .font(.pelicanSerif(22, weight: .light, italic: true))
                        .foregroundStyle(Color.pelicanInk)
                    if let tool {
                        Link(tool.siteURL.host ?? tool.vendor, destination: tool.siteURL)
                            .font(.pelicanSans(11))
                    }
                    Spacer()
                    Button(host.monitorRunning ? "Pause watching" : "Resume watching") {
                        host.setMonitoring(!host.monitorRunning)
                    }
                    .buttonStyle(host.monitorRunning ? .pelicanQuiet : .pelican)
                }

                Text(headline(totals))
                    .font(.pelicanSans(13))
                    .foregroundStyle(Color.pelicanInk.opacity(0.75))

                if !totals.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(totals.prefix(5), id: \.purpose) { entry in
                            LabeledValue(entry.purpose.label, formatBytes(entry.bytes))
                        }
                    }
                }

                Text("Hosts are matched by address, so several of a vendor's services can look alike; contents are not visible.")
                    .font(.pelicanMono(9.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headline(_ totals: [(purpose: HostPurpose, bytes: UInt64)]) -> String {
        let out = totals.reduce(UInt64(0)) { $0 + $1.bytes }
        let name = tool?.name ?? "The AI tools on this Mac"
        guard out > 0 else {
            return store.running.isEmpty
                ? "\(name) hasn't sent anything today."
                : "\(name) is running. Nothing has left this Mac yet today."
        }
        let incidental = totals.filter(\.purpose.isIncidental).reduce(UInt64(0)) { $0 + $1.bytes }
        var line = "\(name) sent \(formatBytes(out)) today"
        if incidental > 0 {
            line += ", of which \(formatBytes(incidental)) was telemetry and error reports you did not ask for"
        }
        return line + "."
    }
}

private struct AwaitingFingerprintCard: View {
    let tool: AITool

    var body: some View {
        PelicanCard {
            VStack(spacing: 12) {
                PelicanEmblem(iconSize: 48)
                Text("\(tool.name) hasn't been fingerprinted yet")
                    .font(.pelicanSerif(20, weight: .light, italic: true))
                    .foregroundStyle(Color.pelicanInk)
                Text("Pelican only attributes traffic to identifiers it has actually seen on a Mac. Install \(tool.name), then run `Pelican --ai-probe` and add what it prints to the catalog. Until then nothing is attributed to it, rather than guessed.")
                    .font(.pelicanSans(11.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Link(tool.siteURL.host ?? tool.siteURL.absoluteString, destination: tool.siteURL)
                    .font(.pelicanSans(11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}

// MARK: - Surfaces

private struct SurfacesCard: View {
    @ObservedObject var store: AIToolsStore
    let tool: AITool?

    var body: some View {
        let groups = store.running.filter { tool == nil || $0.key == tool?.id }
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Running now")
                if groups.isEmpty {
                    Text(tool.map { "\($0.name) isn't running." } ?? "No AI tools are running.")
                        .font(.pelicanSans(11.5))
                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                }
                ForEach(groups.keys.sorted(), id: \.self) { toolID in
                    let name = store.catalog.first { $0.id == toolID }?.name ?? toolID
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(name) — \(groups[toolID]?.count ?? 0) process\((groups[toolID]?.count ?? 0) == 1 ? "" : "es")")
                            .font(.pelicanSans(12, weight: .semibold))
                            .foregroundStyle(Color.pelicanInk)
                        ForEach(Array(chains(groups[toolID] ?? []).enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.chain)
                                    .font(.pelicanMono(10.5))
                                    .foregroundStyle(Color.pelicanInk.opacity(0.8))
                                    .lineLimit(1).truncationMode(.middle)
                                Text(entry.evidence)
                                    .font(.pelicanSans(10))
                                    .foregroundStyle(Color.pelicanInk.opacity(0.45))
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                if entry.count > 1 {
                                    Text("×\(entry.count)")
                                        .font(.pelicanMono(9.5))
                                        .foregroundStyle(Color.pelicanInk.opacity(0.4))
                                }
                            }
                        }
                    }
                }
                if !store.mcpServers.isEmpty {
                    Divider().padding(.vertical, 2)
                    SectionLabel("MCP servers configured")
                    ForEach(store.mcpServers.filter { tool == nil || $0.toolID == tool?.id }) { server in
                        Text("\(server.name) — \(server.host.map { "remote \($0)" } ?? server.command)")
                            .font(.pelicanSans(11))
                            .foregroundStyle(Color.pelicanInk.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Identical chains collapse into one row with a count — an agent runs many shells.
    private func chains(_ attributions: [ToolAttribution]) -> [(chain: String, evidence: String, count: Int)] {
        var order: [String] = []
        var seen: [String: (String, Int)] = [:]
        for attribution in attributions {
            let key = attribution.chainDisplay
            if seen[key] == nil { order.append(key); seen[key] = (attribution.evidence, 0) }
            seen[key]?.1 += 1
        }
        return order.compactMap { key in
            seen[key].map { (chain: key, evidence: $0.0, count: $0.1) }
        }
    }
}

// MARK: - Endpoints

private struct EndpointsCard: View {
    @ObservedObject var store: AIToolsStore
    let tool: AITool?

    var body: some View {
        let rollups = store.day.rollups(forTool: tool?.id)
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Where it went today")
                if rollups.isEmpty {
                    Text("Nothing yet.")
                        .font(.pelicanSans(11.5))
                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                }
                ForEach(rollups.prefix(12)) { rollup in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(rollup.display)
                            .font(.pelicanMono(11))
                            .foregroundStyle(Color.pelicanInk)
                            .lineLimit(1).truncationMode(.middle)
                        PurposeBadge(purpose: rollup.purpose)
                        if rollup.isAmbiguous {
                            Text("address shared with \(rollup.candidates.count - 1) other service\(rollup.candidates.count == 2 ? "" : "s")")
                                .font(.pelicanSans(9.5))
                                .foregroundStyle(Color.pelicanInk.opacity(0.45))
                                .help(rollup.candidates.joined(separator: ", ")
                                      + " all answer at this address; Pelican cannot tell them apart without reading the traffic.")
                        }
                        Spacer(minLength: 0)
                        Text("\(rollup.connections) conn")
                            .font(.pelicanMono(9.5))
                            .foregroundStyle(Color.pelicanInk.opacity(0.4))
                        Text("↑ \(formatBytes(rollup.bytesOut))  ↓ \(formatBytes(rollup.bytesIn))")
                            .font(.pelicanMono(10.5))
                            .foregroundStyle(Color.pelicanInk.opacity(0.65))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

package struct PurposeBadge: View {
    let purpose: HostPurpose

    package init(purpose: HostPurpose) { self.purpose = purpose }

    private var tint: Color {
        switch purpose {
        case .inference, .code: return .pelicanGold
        case .telemetry, .errorReporting: return .pelicanError
        case .agent: return Color.pelicanInk.opacity(0.65)
        default: return Color.pelicanInk.opacity(0.5)
        }
    }

    package var body: some View {
        Text(purpose.label)
            .font(.pelicanSans(9.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Activity

private struct ActivityCard: View {
    @ObservedObject var store: AIToolsStore
    let tool: AITool?
    @State private var filter: Filter = .all
    @State private var selection: ToolFlow.ID?

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "Everything"
        case incidental = "Telemetry"
        case agents = "Agent & MCP"
        case unlisted = "Unlisted hosts"
        var id: String { rawValue }
    }

    var body: some View {
        let flows = store.day.flows(forTool: tool?.id)
        let rows = filtered(flows, filter)
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Connections")
                    Spacer()
                    ForEach(Filter.allCases) { option in
                        FilterChip(option.rawValue, count: filtered(flows, option).count,
                                   selected: filter == option,
                                   tint: option == .incidental ? .pelicanError : nil) {
                            filter = option
                        }
                    }
                }
                if rows.isEmpty {
                    Text(emptyText)
                        .font(.pelicanSans(11.5))
                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                        .padding(.vertical, 8)
                } else {
                    table(rows)
                        .frame(height: min(360, CGFloat(rows.count) * 26 + 32))
                    if let flow = rows.first(where: { $0.id == selection }) {
                        detail(flow)
                    }
                }
                if store.day.overflow > 0 {
                    Text("\(store.day.overflow) more connections today than this day's record keeps; their traffic is still counted above.")
                        .font(.pelicanSans(10.5))
                        .foregroundStyle(Color.pelicanInk.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyText: String {
        switch filter {
        case .all: return "Nothing yet today."
        case .incidental: return "No telemetry or error reports."
        case .agents: return "Nothing from a subprocess or an MCP server."
        case .unlisted: return "Every destination matched a known rule."
        }
    }

    private func filtered(_ flows: [ToolFlow], _ option: Filter) -> [ToolFlow] {
        let chosen: [ToolFlow]
        switch option {
        case .all: chosen = flows
        case .incidental: chosen = flows.filter(\.purpose.isIncidental)
        case .agents: chosen = flows.filter { $0.origin != .tool }
        case .unlisted: chosen = flows.filter { $0.purpose == .agent }
        }
        return chosen.sorted { $0.openedAt > $1.openedAt }
    }

    private func table(_ rows: [ToolFlow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Opened") { flow in
                Text(flow.openedAt.formatted(date: .omitted, time: .standard)).font(.pelicanMono(10.5))
            }
            .width(72)
            TableColumn("Tool") { flow in
                Text(store.catalog.first { $0.id == flow.toolID }?.name ?? flow.toolID)
                    .font(.pelicanSans(11.5, weight: .medium))
            }
            .width(min: 60, ideal: 70)
            TableColumn("From") { flow in
                Text(flow.originLabel).font(.pelicanSans(11.5))
                    .foregroundStyle(flow.origin == .tool ? Color.pelicanInk : Color.pelicanGold)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Remote") { flow in
                Text(flow.remoteDisplay).font(.pelicanMono(10.5)).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 160, ideal: 230)
            TableColumn("Purpose") { flow in PurposeBadge(purpose: flow.purpose) }
                .width(min: 90, ideal: 110)
            TableColumn("Out") { flow in Text(formatBytes(flow.bytesOut)).font(.pelicanMono(10.5)) }
                .width(64)
            TableColumn("In") { flow in Text(formatBytes(flow.bytesIn)).font(.pelicanMono(10.5)) }
                .width(64)
        }
        .pelicanTableBackground()
    }

    private func detail(_ flow: ToolFlow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(flow.originLabel) → \(flow.remoteDisplay)")
                    .font(.pelicanSerif(14, italic: true))
                    .foregroundStyle(Color.pelicanInk)
                PurposeBadge(purpose: flow.purpose)
                Spacer()
            }
            Text(flow.evidence)
                .font(.pelicanSans(11.5))
                .foregroundStyle(Color.pelicanInk.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            if let note = flow.host.ambiguityNote {
                Text(note)
                    .font(.pelicanSans(11))
                    .foregroundStyle(Color.pelicanInk.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(flow.claims, id: \.self) { claim in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "quote.opening").font(.system(size: 8))
                        .foregroundStyle(Color.pelicanInk.opacity(0.35))
                    Text("\(claim) Pelican cannot check this without reading the traffic.")
                        .font(.pelicanSans(10.5))
                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                LabeledValue("started by", flow.chain.joined(separator: " ← "))
                LabeledValue("address", flow.host.address)
                LabeledValue("opened", flow.openedAt.formatted(date: .omitted, time: .standard))
                LabeledValue("closed", flow.closedAt?.formatted(date: .omitted, time: .standard) ?? "still open")
                LabeledValue("seen by", flow.seenBy.map(\.rawValue).joined(separator: " + "))
            }
            HStack(alignment: .top, spacing: 18) {
                LabeledValue("how Pelican knows", flow.basis.label)
                LabeledValue("name from", flow.host.source.label)
                if let hostApp = flow.hostAppName {
                    LabeledValue("running inside", hostApp)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.pelicanFill))
    }
}

/// The sidebar's dot for the AI Tools screen.
package struct AIToolsDot: View {
    @ObservedObject var store: AIToolsStore

    package init(store: AIToolsStore) { _store = ObservedObject(wrappedValue: store) }

    package var body: some View {
        if !store.running.isEmpty {
            StatusDot(color: .pelicanGold)
                .help("\(store.running.count) AI tool\(store.running.count == 1 ? "" : "s") running")
        }
    }
}
