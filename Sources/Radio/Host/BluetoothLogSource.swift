import Foundation
import PelicanKit

/// An event and when it happened.
package struct TimedEvent: Sendable, Equatable {
    package var event: BluetoothEvent
    package var at: Date

    package init(_ event: BluetoothEvent, at: Date) {
        self.event = event
        self.at = at
    }
}

/// Everything the log said since the last batch.
package struct RadioBatch: Sendable, Equatable {
    package var events: [TimedEvent] = []
    package var uninterpreted: [String: Int] = [:]
    package var linesRead = 0
    package var notJSON = 0
    package var oversized = 0
    /// Status changes in order, each with when it happened.
    package var status: [Status] = []

    package struct Status: Sendable, Equatable {
        package var status: FlowSourceStatus
        package var at: Date
    }

    package init() {}

    package var isEmpty: Bool { events.isEmpty && status.isEmpty && linesRead == 0 }
}

/// What the store asks of a log source. A protocol so the store can be tested without a child.
package protocol RadioLogSource: AnyObject, Sendable {
    func start() async
    func stop() async
    /// For quitting: the child has been told to end before this returns.
    func stopNow()
    func drain() async -> RadioBatch
}

/// Streams bluetoothd's log. The entries are not kept by macOS — `log show` finds none
/// afterwards — so only time this source was running is ever covered.
///
/// LIMIT: `log stream` needs an administrator account; on a standard account it exits, and the
/// source reports itself unavailable rather than quiet.
package actor BluetoothLogSource: RadioLogSource {

    /// `--level info` drops the debug flood (per-advertisement scan results, audio quality
    /// samples) while keeping every pattern the parser reads.
    package static let predicate = #"subsystem == "com.apple.bluetooth""#
    package static let command = ChildLineStream.Command(
        "/usr/bin/log", ["stream", "--style", "ndjson", "--level", "info", "--predicate", predicate])

    private let child: ChildLineStream
    private let processName: @Sendable (Int32) -> String?
    private var pending = RadioBatch()
    private var reader: Task<Void, Never>?
    private var sawLineSinceStart = false

    /// `processName` checks the pid a session string carries; by default, against the running
    /// process table.
    package init(command: ChildLineStream.Command = BluetoothLogSource.command,
                 restart: ChildLineStream.Restart? = .standard,
                 processName: @escaping @Sendable (Int32) -> String? = { ProcessIdentity.name(pid: $0) }) {
        self.child = ChildLineStream(command: command, label: "bluetooth-log", restart: restart)
        self.processName = processName
    }

    package func start() {
        guard reader == nil else { return }
        let (stream, sink) = AsyncStream.makeStream(of: ChildLineStream.Event.self,
                                                    bufferingPolicy: .bufferingNewest(4096))
        child.start(into: sink)
        reader = Task { [weak self] in
            for await event in stream {
                await self?.receive(event)
            }
        }
    }

    package func stop() {
        child.stop()
        reader?.cancel()
        reader = nil
        pending.status.append(.init(status: .stopped, at: Date()))
    }

    nonisolated package func stopNow() {
        child.stopNow()
    }

    package func drain() -> RadioBatch {
        defer { pending = RadioBatch() }
        return pending
    }

    // MARK: - Test seam (internal; used through @testable import)

    func inject(lines: [String], at time: Date) { take(lines, at: time) }

    // MARK: - Reading

    private func receive(_ event: ChildLineStream.Event) {
        switch event {
        case .started:
            sawLineSinceStart = false
        case .lines(let lines, let at):
            take(lines, at: at)
        case .oversized(let count):
            pending.oversized += count
        case .exited(let status, let stderr, let at):
            let why = stderr.isEmpty ? "" : ": \(stderr)"
            pending.status.append(.init(status: .unavailable("log exited with status \(status)\(why)"), at: at))
        case .failedToStart(let message, let at):
            pending.status.append(.init(status: .unavailable("log could not start: \(message)"), at: at))
        }
    }

    private func take(_ lines: [String], at arrival: Date) {
        // Running means lines are arriving: a `log` that starts and is refused exits before
        // writing any, and must never count as watching.
        if !sawLineSinceStart, !lines.isEmpty {
            sawLineSinceStart = true
            pending.status.append(.init(status: .running, at: arrival))
        }
        for line in lines {
            pending.linesRead += 1
            switch BluetoothLogParser.parse(line) {
            case .notJSON:
                pending.notJSON += 1
            case .uninterpreted(let key):
                if pending.uninterpreted[key] != nil || pending.uninterpreted.count < RadioDay.uninterpretedCap {
                    pending.uninterpreted[key, default: 0] += 1
                }
            case .event(let event, let at, _):
                pending.events.append(TimedEvent(confirmed(event), at: at ?? arrival))
            }
        }
    }

    /// A session string's pid is checked against the process table: if that pid now belongs to
    /// something else, the name is kept and the pid dropped.
    private func confirmed(_ event: BluetoothEvent) -> BluetoothEvent {
        switch event {
        case .scanRequested(let client, let active): return .scanRequested(confirmed(client), active: active)
        case .scanStopRequested(let client): return .scanStopRequested(confirmed(client))
        case .request(let client, let message): return .request(confirmed(client), message: message)
        case .indication(let client): return .indication(confirmed(client))
        case .scanAgents(let clients): return .scanAgents(clients.map(confirmed))
        default: return event
        }
    }

    /// Names already looked up. Forgotten every minute, so a pid reused by another process is
    /// not confirmed as the one that held it before.
    private var checked: [Int32: String?] = [:]
    private var checkedSince = Date()

    private func confirmed(_ client: RadioClient) -> RadioClient {
        guard case .process(let name, let pid?) = client else { return client }
        if Date().timeIntervalSince(checkedSince) > 60 || checked.count > 512 {
            checked.removeAll()
            checkedSince = Date()
        }
        let actual: String?
        if let cached = checked[pid] {
            actual = cached
        } else {
            actual = processName(pid)
            checked[pid] = actual
        }
        // The kernel's short name can be truncated; compare case-insensitively by prefix.
        guard let actual, actual.lowercased().hasPrefix(String(name.lowercased().prefix(15)))
                || name.lowercased().hasPrefix(actual.lowercased())
        else { return .process(name: name, pid: nil) }
        return client
    }
}
