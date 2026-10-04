import Foundation
import PelicanKit

/// Runs preset/custom prompts over batches of flows through the on-device
/// model and parses verdicts back out of the streamed reply.
@MainActor
package final class AnalysisEngine: ObservableObject {

    package struct AnalysisResult: Identifiable {
        package let id = UUID()
        package let flow: Flow
        package let verdict: Verdict
    }

    @Published package var isAnalyzing = false
    @Published package var progressText = ""
    @Published package var results: [AnalysisResult] = []
    @Published package var rawOutput = ""
    @Published package var analysisError: String?

    private var runTask: Task<Void, Never>?
    /// Shared with every other user of the model, so generations take turns.
    package let gate: ModelGate

    static let batchSize = 35

    package init(gate: ModelGate = ModelGate()) {
        self.gate = gate
    }

    package nonisolated static let systemPrompt = """
    You are a network threat-hunting analyst reviewing flows captured on a \
    personal macOS machine. You will receive an instruction and a numbered TSV \
    table of network flows with columns: row, process, pid, direction, proto, \
    remote IP, reverse-DNS host ("-" if none), port, bytes_in, bytes_out, \
    age_seconds, state.

    Your ENTIRE reply must be JSON objects, one per line, and nothing else — \
    no explanations, no numbered lists, no markdown, no prose before or after. \
    One object per flagged row, in exactly this shape:
    {"row": 3, "verdict": "suspicious", "score": 8, "reason": "unsigned helper uploading 9 MB to raw IP on port 8443"}
    {"row": 7, "verdict": "ok", "score": 2, "reason": "Apple push service on standard port"}

    Score 0 = certainly benign, 10 = almost certainly malicious. Output a line \
    only for rows that are suspicious or notable; omit clearly benign rows. If \
    nothing is notable, reply with exactly: none
    """

    package func run(
        flows: [Flow],
        instruction: String,
        presetName: String,
        llm: LLMSession,
        onVerdict: @escaping @MainActor (FlowKey, Verdict) -> Void
    ) {
        guard !isAnalyzing else { return }
        let candidates = Self.prefilter(flows)
        guard !candidates.isEmpty else {
            analysisError = "No analyzable flows — start the monitor and let it collect some traffic first."
            return
        }

        isAnalyzing = true
        analysisError = nil
        results = []
        rawOutput = ""

        let batches = stride(from: 0, to: candidates.count, by: Self.batchSize).map {
            Array(candidates[$0..<min($0 + Self.batchSize, candidates.count)])
        }

        runTask = Task {
            defer {
                isAnalyzing = false
                progressText = ""
                runTask = nil
            }
            for (index, batch) in batches.enumerated() {
                if Task.isCancelled { return }
                progressText = "Analyzing batch \(index + 1) of \(batches.count) (\(batch.count) flows)…"
                let user = instruction + "\n\nFlows:\n" + Self.serialize(batch) + Self.replyReminder
                let reply: String
                do {
                    // Wait for the model to be free; another pass may be using it.
                    reply = try await gate.run {
                        var text = ""
                        for try await chunk in await llm.reply(system: Self.systemPrompt, user: user) {
                            if Task.isCancelled { break }
                            text += chunk
                        }
                        return text
                    }
                } catch {
                    analysisError = "Model error: \(error.localizedDescription)"
                    return
                }
                if Task.isCancelled { return }
                rawOutput += (rawOutput.isEmpty ? "" : "\n") + reply
                for (row, verdict) in Self.parseVerdicts(from: reply, presetName: presetName)
                where row >= 1 && row <= batch.count {
                    let flow = batch[row - 1]
                    results.append(AnalysisResult(flow: flow, verdict: verdict))
                    onVerdict(flow.id, verdict)
                }
            }
        }
    }

    package func cancel() {
        runTask?.cancel()
    }

    /// Drop rows the model can say nothing useful about: listeners and flows
    /// with no concrete remote endpoint. Sort the most interesting first —
    /// outbound, raw-IP, non-443 — so early batches carry the signal.
    nonisolated static func prefilter(_ flows: [Flow]) -> [Flow] {
        flows
            .filter { $0.hasConcreteRemote && $0.direction != .listening }
            .sorted { a, b in
                func rank(_ f: Flow) -> Int {
                    var r = 0
                    if f.direction == .outbound { r += 4 }
                    if f.resolvedHost == nil { r += 2 }
                    if f.remotePort != 443 { r += 1 }
                    return r
                }
                return rank(a) > rank(b)
            }
    }

    /// Numbered TSV, one flow per line (~25 tokens/row).
    nonisolated static func serialize(_ flows: [Flow]) -> String {
        let now = Date()
        var lines = ["row\tprocess\tpid\tdir\tproto\tremote\thost\tport\tin_B\tout_B\tage_s\tstate"]
        for (index, flow) in flows.enumerated() {
            let age = Int(now.timeIntervalSince(flow.firstSeen))
            lines.append(
                [
                    "\(index + 1)",
                    flow.processName,
                    "\(flow.pid)",
                    flow.direction.rawValue,
                    flow.proto.rawValue,
                    flow.remoteAddress,
                    flow.resolvedHost ?? "-",
                    flow.remotePort.map(String.init) ?? "-",
                    "\(flow.bytesIn)",
                    "\(flow.bytesOut)",
                    "\(age)",
                    flow.state == .none ? "-" : flow.state.label,
                ].joined(separator: "\t")
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Appended after the flow table — small models follow the most recent
    /// instruction best, so the output shape is restated at the reply point.
    package nonisolated static let replyReminder = """


    Now output your verdicts. Do not repeat the input table. For each \
    suspicious or notable row output exactly one JSON object on its own line, \
    in exactly this shape, and nothing else:
    {"row": 1, "verdict": "suspicious", "score": 8, "reason": "short reason here"}
    """

    /// Lenient JSON-lines scan: take the outermost {...} of each line, tolerate
    /// fences and stray prose, skip anything unparseable (it stays visible in
    /// the raw-output disclosure).
    package nonisolated static func parseVerdicts(from text: String, presetName: String) -> [(row: Int, verdict: Verdict)] {
        var out: [(Int, Verdict)] = []
        for line in text.split(separator: "\n") {
            guard let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"),
                  open < close,
                  let data = String(line[open...close]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let row = object["row"] as? Int,
                  let verdictString = object["verdict"] as? String
            else { continue }
            let label = Verdict.Label(rawValue: verdictString.lowercased()) ?? .unknown
            let verdict = Verdict(
                label: label,
                score: min(max(object["score"] as? Int ?? 0, 0), 10),
                reason: object["reason"] as? String ?? "",
                presetName: presetName,
                at: Date()
            )
            out.append((row, verdict))
        }
        return out
    }
}
