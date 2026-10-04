import AppKit
import Combine
import Foundation
import PelicanAITools
import PelicanAnalyst
import PelicanKit
import PelicanRao
import PelicanUI
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case rao = "Rao"
    case aiTools = "AI Tools"
    case connections = "Connections"
    case processes = "Processes"
    case analysis = "Analysis"
    case model = "Model"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .rao: return "checkmark.shield"
        case .aiTools: return "bubble.left.and.text.bubble.right"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .processes: return "square.grid.2x2"
        case .analysis: return "sparkle.magnifyingglass"
        case .model: return "arrow.down.circle"
        }
    }
}

@MainActor
final class AppState: ObservableObject {

    /// One per process: the window, the menubar item and the app delegate share it, and it
    /// outlives the window so monitoring continues with the window closed.
    static let shared = AppState()

    // MARK: Navigation

    @Published var screen: Screen = .rao

    // MARK: Monitor

    @Published var flows: [Flow] = []
    @Published var recentClosed: [Flow] = []
    @Published var events: [FlowEvent] = []
    @Published var monitorRunning = false
    @Published var parseSkips = 0
    @Published var pollInterval: Double = 4
    @Published var captureStatus: [FlowSourceKind: FlowSourceStatus] = [:]
    /// Loopback (this-Mac-only) flows are captured for the Rao trust ledger; the general
    /// screens hide them unless asked.
    @Published var showLoopback = false

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
    /// Ambient's trust ledger — the Rao tab.
    let rao = TrustMonitor()
    /// The AI tools on this Mac — the AI Tools tab.
    let aiTools = AIToolsStore()
    private var cancellables: Set<AnyCancellable> = []
    private(set) var llm: LLMSession?
    private var snapshotTask: Task<Void, Never>?

    private static let modelIdKey = "pelican.modelId"
    private static let knownModelsKey = "pelican.knownModels"

    init() {
        let defaults = UserDefaults.standard
        modelId = defaults.string(forKey: Self.modelIdKey) ?? ModelStore.defaultModelId
        let known = defaults.stringArray(forKey: Self.knownModelsKey) ?? []
        knownModels = known.isEmpty ? [ModelStore.defaultModelId] : known

        // Poll as often as the most demanding feature needs (CaptureDemand).
        rao.captureDemand.combineLatest(aiTools.captureDemand.prepend(.idle))
            .map { max($0, $1) }
            .removeDuplicates()
            .sink { [weak self] demand in self?.setCadence(demand.pollInterval) }
            .store(in: &cancellables)
    }

    /// What feature screens may read from, and ask of, the app.
    var host: MonitorHost {
        MonitorHost(
            monitorRunning: monitorRunning,
            pollInterval: pollInterval,
            modelReady: modelReady,
            setMonitoring: { [weak self] on in on ? self?.startMonitor() : self?.stopMonitor() },
            analyze: { [weak self] instruction, presetName, flows in
                self?.runAnalysis(instruction: instruction, presetName: presetName, flows: flows)
                self?.screen = .analysis
            })
    }

    /// Start watching at launch — Pelican is meant to run all day.
    func launch() {
        rao.start()
        aiTools.start()
        // Trace each new flow's process the moment it appears, before it can exit.
        let aiTools = self.aiTools
        Task { await monitor.onSighting { pid, time in aiTools.sight(pid: pid, at: time) } }
        startMonitor()
    }

    /// Write every feature's day before quitting.
    func flushNow() {
        rao.flushNow()
        aiTools.flushNow()
    }

    private func setCadence(_ seconds: Double) {
        guard pollInterval != seconds else { return }
        pollInterval = seconds
        Task { await monitor.setCadence(seconds) }
    }

    // MARK: - Monitor control

    func startMonitor() {
        guard !monitorRunning else { return }
        monitorRunning = true
        rao.setObserving(true)
        aiTools.setObserving(true)
        let cadence = pollInterval
        if snapshotTask == nil {
            snapshotTask = Task {
                // Obtain the stream (registering the continuation) before the
                // first tick so no snapshot is dropped.
                let stream = await monitor.snapshots()
                await monitor.start(cadence: cadence)
                for await snapshot in stream {
                    apply(snapshot)
                }
            }
        } else {
            Task { await monitor.start(cadence: cadence) }
        }
    }

    func stopMonitor() {
        monitorRunning = false
        rao.setObserving(false)
        aiTools.setObserving(false)
        Task { await monitor.stop() }
    }

    private func apply(_ snapshot: NetworkMonitor.Snapshot) {
        flows = snapshot.flows
        recentClosed = snapshot.recentClosed
        parseSkips = snapshot.parseSkips
        if captureStatus != snapshot.sourceStatus { captureStatus = snapshot.sourceStatus }
        rao.ingest(snapshot)
        aiTools.ingest(snapshot)
        if !snapshot.newEvents.isEmpty {
            events.insert(contentsOf: snapshot.newEvents.reversed(), at: 0)
            if events.count > Self.eventLogLimit {
                events.removeLast(events.count - Self.eventLogLimit)
            }
        }
    }

    var processRollups: [ProcessRollup] {
        Dictionary(grouping: showLoopback ? flows : flows.filter { $0.scope == .external }, by: \.pid)
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
        guard llm != nil else {
            analysis.analysisError = "Load the model first (Model tab)."
            return
        }
        let target = scope == .active ? flows : flows + recentClosed
        runAnalysis(instruction: instruction, presetName: presetName, flows: target)
    }

    /// Analyse an explicit set of flows (the Rao tab passes the day's external connections).
    func runAnalysis(instruction: String, presetName: String, flows target: [Flow]) {
        guard let llm else {
            analysis.analysisError = "Load the model first (Model tab)."
            return
        }
        analysis.run(flows: target, instruction: instruction, presetName: presetName, llm: llm) { [weak self] key, verdict in
            guard let self else { return }
            Task { await self.monitor.applyVerdict(verdict, to: key) }
        }
    }
}
