/// How closely capture must watch, as a feature needs it. The app polls nettop at the most
/// demanding level any feature asks for; NetworkStatistics events are live regardless.
package enum CaptureDemand: Int, Sendable, Comparable {
    /// Nothing a feature watches is running.
    case idle
    /// Watched processes are running and connect through kernel sockets, which socket events
    /// report as they open.
    case active
    /// A watched process connects through macOS's user-space network stack (URLSession),
    /// which only nettop sees. URLSession keeps a connection open ~30 s after a request, so a
    /// 1 s poll catches it, for about 0.03 s of CPU per poll.
    case userSpace

    /// nettop's poll interval, in seconds.
    package var pollInterval: Double {
        switch self {
        case .idle: return 5
        case .active: return 2
        case .userSpace: return 1
        }
    }

    package static func < (a: CaptureDemand, b: CaptureDemand) -> Bool { a.rawValue < b.rawValue }
}
