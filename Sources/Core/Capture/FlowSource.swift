import Foundation

enum FlowSourceStatus: Sendable, Equatable, Codable {
    case running
    case stopped
    case unavailable(String)

    var description: String {
        switch self {
        case .running: return "running"
        case .stopped: return "stopped"
        case .unavailable(let reason): return "unavailable — \(reason)"
        }
    }
}

/// What a capture backend reports. nettop sends whole tables; NetworkStatistics sends one
/// socket at a time, keyed by a token that lives from the socket's add until its removal.
enum FlowSourceEvent: Sendable {
    case snapshot([FlowSample], skipped: Int, at: Date)
    case upsert(FlowSample, token: UInt64, at: Date)
    case removed(token: UInt64, at: Date)
    case status(FlowSourceKind, FlowSourceStatus)
}

protocol FlowSource: AnyObject, Sendable {
    var kind: FlowSourceKind { get }
    func start(into sink: AsyncStream<FlowSourceEvent>.Continuation)
    /// Poll/refresh interval in seconds; applied from the next iteration.
    func setCadence(_ seconds: Double)
    func stop()
}

enum FlowSourceFactory {
    /// NetworkStatistics when it loads (event-driven, sees sockets that open and close
    /// between polls), and nettop always (fallback and cross-check).
    static func make() -> (sources: [any FlowSource], unavailable: [FlowSourceKind: String]) {
        var sources: [any FlowSource] = []
        var unavailable: [FlowSourceKind: String] = [:]
        switch NStatFlowSource.make() {
        case .success(let source): sources.append(source)
        case .failure(let error): unavailable[.nstat] = error.reason
        }
        sources.append(NettopFlowSource())
        return (sources, unavailable)
    }
}
