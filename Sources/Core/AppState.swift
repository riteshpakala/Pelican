import Foundation
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case connections = "Connections"
    case processes = "Processes"
    case analysis = "Analysis"
    case model = "Model"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .processes: return "square.grid.2x2"
        case .analysis: return "sparkle.magnifyingglass"
        case .model: return "arrow.down.circle"
        }
    }
}

@MainActor
final class AppState: ObservableObject {

    // MARK: Navigation

    @Published var screen: Screen = .connections

    // MARK: Monitor

    @Published var flows: [Flow] = []
    @Published var recentClosed: [Flow] = []
    @Published var events: [FlowEvent] = []
    @Published var monitorRunning = false
    @Published var parseSkips = 0
    @Published var pollInterval: Double = 4

    static let eventLogLimit = 300

    // MARK: Model

    @Published var modelId: String
    @Published var knownModels: [String]
    @Published var warmProgress: Double?
    @Published var warmStatus = ""
    @Published var modelError: String?
    @Published var modelReady = false
    let metallibPresent = ModelStore.metallibPresent

    let monitor = NetworkMonitor()
    let analysis = AnalysisEngine()
    private(set) var llm: LLMSession?
    private var snapshotTask: Task<Void, Never>?

    private static let modelIdKey = "pelican.modelId"
    private static let knownModelsKey = "pelican.knownModels"

    init() {
        let defaults = UserDefaults.standard
        modelId = defaults.string(forKey: Self.modelIdKey) ?? ModelStore.defaultModelId
        let known = defaults.stringArray(forKey: Self.knownModelsKey) ?? []
        knownModels = known.isEmpty ? [ModelStore.defaultModelId] : known
    }

    // MARK: - Monitor control

    func startMonitor() {
        guard !monitorRunning else { return }
        monitorRunning = true
        let interval = Duration.seconds(pollInterval)
        if snapshotTask == nil {
            snapshotTask = Task {
                // Obtain the stream (registering the continuation) before the
                // first tick so no snapshot is dropped.
                let stream = await monitor.snapshots()
                await monitor.start(interval: interval)
                for await snapshot in stream {
                    apply(snapshot)
                }
            }
        } else {
            Task { await monitor.start(interval: interval) }
        }
    }

    func stopMonitor() {
        monitorRunning = false
        Task { await monitor.stop() }
    }

    private func apply(_ snapshot: NetworkMonitor.Snapshot) {
        flows = snapshot.flows
        recentClosed = snapshot.recentClosed
        parseSkips = snapshot.parseSkips
        if !snapshot.newEvents.isEmpty {
            events.insert(contentsOf: snapshot.newEvents.reversed(), at: 0)
            if events.count > Self.eventLogLimit {
                events.removeLast(events.count - Self.eventLogLimit)
            }
        }
    }

    var processRollups: [ProcessRollup] {
        Dictionary(grouping: flows, by: \.pid)
            .map { pid, flows in
                ProcessRollup(pid: pid, name: flows[0].processName, flows: flows)
            }
            .sorted { $0.totalOut > $1.totalOut }
    }

    // MARK: - Model control

    func warmModel() {
        guard warmProgress == nil else { return }
        let id = modelId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        modelError = nil
        modelReady = false
        warmProgress = 0
        warmStatus = "Preparing…"
        rememberModel(id)

        Task {
            do {
                try await ModelStore.warm(id: id) { fraction, status in
                    Task { @MainActor in
                        self.warmProgress = fraction
                        self.warmStatus = status
                    }
                }
                warmStatus = "Loading into memory…"
                let session = LLMSession(modelId: id)
                try await session.warmup()
                llm = session
                modelReady = true
                warmStatus = "Ready"
            } catch {
                modelError = "\(error)"
                warmStatus = ""
            }
            warmProgress = nil
        }
    }

    private func rememberModel(_ id: String) {
        if !knownModels.contains(id) {
            knownModels.append(id)
        }
        let defaults = UserDefaults.standard
        defaults.set(id, forKey: Self.modelIdKey)
        defaults.set(knownModels, forKey: Self.knownModelsKey)
    }

    // MARK: - Analysis

    enum AnalysisScope: String, CaseIterable, Identifiable {
        case active = "Active"
        case activeAndRecent = "Active + recent"
        var id: String { rawValue }
    }

    func runAnalysis(instruction: String, presetName: String, scope: AnalysisScope) {
        guard let llm else {
            analysis.analysisError = "Load the model first (Model tab)."
            return
        }
        let target = scope == .active ? flows : flows + recentClosed
        analysis.run(flows: target, instruction: instruction, presetName: presetName, llm: llm) { [weak self] key, verdict in
            guard let self else { return }
            Task { await self.monitor.applyVerdict(verdict, to: key) }
        }
    }
}
