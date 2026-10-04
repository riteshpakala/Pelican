import Foundation
import PelicanKit

/// Rao's headless diagnostic, run from the command line (see main.swift).
package enum RaoProbe {
    /// `Pelican --trust-probe [seconds]`: run Ambient's trust monitor headless and print what
    /// it concluded, then the day's report. Uses PELICAN_LEDGER_DIR when set.
    @MainActor
    package static func trust(seconds: Double) async {
        let monitor = TrustMonitor(app: .ambient)
        let network = NetworkMonitor()
        let stream = await network.snapshots()
        await network.start(cadence: 2)
        monitor.start()
        let reader = Task { @MainActor in
            for await snapshot in stream { monitor.ingest(snapshot) }
        }
        try? await Task.sleep(for: .seconds(seconds))
        reader.cancel()
        await network.stop()
        let assessment = monitor.assessment
        print("level:   \(assessment.level.rawValue) — \(assessment.level.displayName)")
        print("summary: \(assessment.summary)")
        for reason in assessment.reasons { print("  reason: \(reason)") }
        print("mode:    \(monitor.effectiveMode.displayName) (detected: \(monitor.consent?.mode.displayName ?? "unreadable"))")
        print("capture: \(monitor.captureStatus.map { "\($0.key.rawValue)=\($0.value.description)" }.sorted().joined(separator: ", "))")
        print("processes:")
        for process in monitor.processes {
            print("  \(process.name)[\(process.pid)] \(process.attribution.confidence) — \(process.attribution.evidence)")
        }
        print("findings:")
        for finding in monitor.findings { print("  [\(finding.severity.rawValue)] \(finding.title) — \(finding.detail)") }
        let flows = monitor.ledger.flows
        print("flows: \(flows.count) (local \(flows.filter { $0.classification.kind == .local }.count), expected \(flows.filter { $0.classification.kind == .expected }.count), unexpected \(flows.filter { $0.classification.kind == .unexpected }.count))")
        for flow in flows.prefix(12) {
            print("  \(flow.process) \(flow.proto.rawValue) \(flow.direction.rawValue) \(flow.remoteDisplay) [\(flow.classification.kind.rawValue)] \(flow.classification.note)")
        }
        monitor.flushNow()
        print("--- report ---")
        print(RaoReportRenderer.markdown(monitor.report()))
    }
}
