import Foundation

/// Polls `/usr/bin/nettop` and reports the whole flow table each time. Only sockets open at
/// the moment of a poll are visible — a connection that opens and closes between two polls
/// leaves no trace — which is why NetworkStatistics runs beside it when available.
final class NettopFlowSource: FlowSource, @unchecked Sendable {
    let kind: FlowSourceKind = .nettop

    private let queue = DispatchQueue(label: "pelican.capture.nettop", qos: .utility)
    private var cadence: Double = 4      // queue-confined
    private var running = false          // queue-confined
    private var generation = 0           // queue-confined; invalidates a stopped loop

    func start(into sink: AsyncStream<FlowSourceEvent>.Continuation) {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.generation += 1
            sink.yield(.status(.nettop, .running))
            self.poll(sink: sink, generation: self.generation)
        }
    }

    func setCadence(_ seconds: Double) {
        queue.async { self.cadence = max(0.5, seconds) }
    }

    func stop() {
        queue.async {
            self.running = false
            self.generation += 1
        }
    }

    private func poll(sink: AsyncStream<FlowSourceEvent>.Continuation, generation: Int) {
        guard running, generation == self.generation else { return }
        if let csv = Self.runNettop() {
            let parsed = NettopParser.parse(csv)
            sink.yield(.snapshot(parsed.flows, skipped: parsed.skippedLines, at: Date()))
        }
        queue.asyncAfter(deadline: .now() + cadence) { [weak self] in
            self?.poll(sink: sink, generation: generation)
        }
    }

    /// `-n` keeps every endpoint numeric (loopback peers would otherwise print as
    /// "localhost"), and there is no `-t external`: loopback traffic is part of the picture.
    static let arguments = ["-x", "-n", "-L", "1", "-J", "bytes_in,bytes_out,state,interface"]

    private static func runNettop() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // Read to EOF before waiting: the output can exceed the 64 KB pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
