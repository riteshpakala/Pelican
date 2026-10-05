import Darwin
import Foundation

/// Splits a byte stream into lines. Pure, so the awkward cases — a line split across reads, a
/// last line with no newline, a runaway line — are tested without a process.
package struct LineSplitter: Sendable {
    package let maxLineLength: Int
    private var buffer: [UInt8] = []
    private var discarding = false

    package init(maxLineLength: Int = 64 * 1024) {
        self.maxLineLength = maxLineLength
    }

    /// The lines these bytes complete, without their newline, and how many over-long lines were
    /// dropped. A line past the limit is dropped whole rather than cut into fragments that would
    /// parse as something else.
    package mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> (lines: [String], oversized: Int)
    where Bytes.Element == UInt8 {
        var lines: [String] = []
        var oversized = 0
        for byte in bytes {
            if byte == 0x0A {
                if discarding {
                    discarding = false
                } else {
                    lines.append(String(decoding: buffer, as: UTF8.self))
                }
                buffer.removeAll(keepingCapacity: true)
            } else if !discarding {
                buffer.append(byte)
                if buffer.count > maxLineLength {
                    discarding = true
                    oversized += 1
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        return (lines, oversized)
    }

    /// Whatever is left when the stream ends.
    package mutating func finish() -> [String] {
        defer {
            buffer.removeAll()
            discarding = false
        }
        return buffer.isEmpty || discarding ? [] : [String(decoding: buffer, as: UTF8.self)]
    }
}

/// Runs a long-lived command and hands back its standard output line by line, starting it
/// again with backoff when it exits on its own. `nettop` is run once per poll; this is for tools
/// that stream, like `log stream`.
///
/// Queue-confined like the capture sources: one serial queue owns the child, its pipes and a
/// generation counter, so a stopped child's late callbacks are ignored.
///
/// LIMIT: macOS cannot tie a child's life to its parent's. `stopNow()` ends it on Quit; if
/// Pelican is killed instead, the child lives on until its next write to the closed pipe fails.
package final class ChildLineStream: @unchecked Sendable {

    package struct Command: Sendable, Equatable {
        package var executable: String
        package var arguments: [String]

        package init(_ executable: String, _ arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }

        package var display: String { ([executable] + arguments).joined(separator: " ") }
    }

    /// How soon to try again after the child exits on its own. Each quick exit doubles the wait,
    /// up to `maximum`; a run that lasted `healthyAfter` seconds starts the count over.
    package struct Restart: Sendable {
        package var initial: Double
        package var maximum: Double
        package var healthyAfter: Double

        package init(initial: Double, maximum: Double, healthyAfter: Double) {
            self.initial = initial
            self.maximum = maximum
            self.healthyAfter = healthyAfter
        }

        package static let standard = Restart(initial: 1, maximum: 60, healthyAfter: 30)
    }

    package enum Event: Sendable, Equatable {
        case started(pid: Int32, at: Date)
        case lines([String], at: Date)
        /// Lines longer than the limit, dropped whole.
        case oversized(Int)
        /// The child exited without being asked to. `stderr` is the start of what it wrote there.
        case exited(status: Int32, stderr: String, at: Date)
        case failedToStart(String, at: Date)
    }

    package let command: Command
    private let restart: Restart?
    private let maxLineLength: Int
    private let queue: DispatchQueue

    private var running = false     // queue-confined
    private var generation = 0      // queue-confined; invalidates a stopped child's callbacks
    private var backoff: Double = 0 // queue-confined
    private var current: Run?       // queue-confined

    /// One launch of the child. Every field is touched only on the queue.
    private final class Run {
        let process: Process
        let output: DispatchSourceRead
        let errors: DispatchSourceRead
        let outputDescriptor: Int32
        let errorDescriptor: Int32
        let startedAt: Date
        var splitter: LineSplitter
        var stderr: [UInt8] = []
        /// Set at end of file. The descriptor is released with its source after that, and its
        /// number may be reused, so it must never be read again.
        var outputDone = false
        var errorsDone = false

        init(process: Process, output: DispatchSourceRead, errors: DispatchSourceRead,
             outputDescriptor: Int32, errorDescriptor: Int32, maxLineLength: Int) {
            self.process = process
            self.output = output
            self.errors = errors
            self.outputDescriptor = outputDescriptor
            self.errorDescriptor = errorDescriptor
            self.startedAt = Date()
            self.splitter = LineSplitter(maxLineLength: maxLineLength)
        }

        func close() {
            output.cancel()
            errors.cancel()
        }
    }

    package init(command: Command, label: String, restart: Restart? = .standard,
                 maxLineLength: Int = 64 * 1024) {
        self.command = command
        self.restart = restart
        self.maxLineLength = maxLineLength
        self.queue = DispatchQueue(label: "pelican.child.\(label)", qos: .utility)
    }

    package func start(into sink: AsyncStream<Event>.Continuation) {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.generation += 1
            self.backoff = self.restart?.initial ?? 0
            self.launch(sink: sink, generation: self.generation)
        }
    }

    package func stop() {
        queue.async { self.halt() }
    }

    /// For quitting: the child has been told to end before this returns. Never call it from the
    /// stream's own queue.
    package func stopNow() {
        queue.sync { self.halt() }
    }

    private func halt() {
        running = false
        generation += 1
        guard let run = current else { return }
        current = nil
        run.close()
        if run.process.isRunning { run.process.terminate() }
    }

    // MARK: - One run

    private func launch(sink: AsyncStream<Event>.Continuation, generation: Int) {
        guard running, generation == self.generation else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            self?.queue.async { self?.ended(status: status, sink: sink, generation: generation) }
        }
        do {
            try process.run()
        } catch {
            sink.yield(.failedToStart(error.localizedDescription, at: Date()))
            scheduleRestart(sink: sink, generation: generation, ranFor: 0)
            return
        }

        let outputDescriptor = output.fileHandleForReading.fileDescriptor
        let errorDescriptor = errors.fileHandleForReading.fileDescriptor
        for descriptor in [outputDescriptor, errorDescriptor] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        let outputSource = DispatchSource.makeReadSource(fileDescriptor: outputDescriptor, queue: queue)
        let errorSource = DispatchSource.makeReadSource(fileDescriptor: errorDescriptor, queue: queue)
        let run = Run(process: process, output: outputSource, errors: errorSource,
                      outputDescriptor: outputDescriptor, errorDescriptor: errorDescriptor,
                      maxLineLength: maxLineLength)
        outputSource.setEventHandler { [weak self] in
            self?.drain(run, sink: sink, generation: generation)
        }
        errorSource.setEventHandler { [weak self] in
            self?.drainErrors(run, generation: generation)
        }
        // The pipes own the descriptors; holding them until the sources are cancelled keeps a
        // descriptor from being closed while a source still watches it.
        outputSource.setCancelHandler { _ = output }
        errorSource.setCancelHandler { _ = errors }
        current = run
        outputSource.resume()
        errorSource.resume()
        sink.yield(.started(pid: process.processIdentifier, at: run.startedAt))
    }

    private func drain(_ run: Run, sink: AsyncStream<Event>.Continuation, generation: Int) {
        guard generation == self.generation, current === run, !run.outputDone else { return }
        var lines: [String] = []
        var oversized = 0
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(run.outputDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let fed = run.splitter.feed(chunk[0..<count])
                lines += fed.lines
                oversized += fed.oversized
            } else if count == 0 {
                lines += run.splitter.finish()
                run.outputDone = true
                run.output.cancel()
                break
            } else {
                if errno == EINTR { continue }
                break  // EAGAIN: nothing more for now
            }
        }
        if !lines.isEmpty { sink.yield(.lines(lines, at: Date())) }
        if oversized > 0 { sink.yield(.oversized(oversized)) }
    }

    /// Keeps the start of what the child writes to stderr — enough to say why it stopped — and
    /// discards the rest so a chatty child can never fill the pipe and stall.
    private func drainErrors(_ run: Run, generation: Int) {
        guard generation == self.generation, current === run, !run.errorsDone else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(run.errorDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                if run.stderr.count < 1024 { run.stderr += chunk[0..<min(count, 1024 - run.stderr.count)] }
            } else if count == 0 {
                run.errorsDone = true
                run.errors.cancel()
                break
            } else {
                if errno == EINTR { continue }
                break
            }
        }
    }

    private func ended(status: Int32, sink: AsyncStream<Event>.Continuation, generation: Int) {
        guard generation == self.generation, let run = current else { return }
        // Whatever the child wrote before exiting is still in the pipes.
        drain(run, sink: sink, generation: generation)
        drainErrors(run, generation: generation)
        let leftover = run.splitter.finish()
        if !leftover.isEmpty { sink.yield(.lines(leftover, at: Date())) }
        current = nil
        run.close()
        let firstLine = String(decoding: run.stderr, as: UTF8.self)
            .split(separator: "\n").first.map(String.init) ?? ""
        sink.yield(.exited(status: status, stderr: firstLine, at: Date()))
        scheduleRestart(sink: sink, generation: generation, ranFor: Date().timeIntervalSince(run.startedAt))
    }

    private func scheduleRestart(sink: AsyncStream<Event>.Continuation, generation: Int, ranFor: Double) {
        guard running, generation == self.generation else { return }
        guard let restart else {
            running = false
            return
        }
        if ranFor >= restart.healthyAfter { backoff = restart.initial }
        let delay = backoff
        backoff = min(max(backoff * 2, restart.initial), restart.maximum)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launch(sink: sink, generation: generation)
        }
    }
}
