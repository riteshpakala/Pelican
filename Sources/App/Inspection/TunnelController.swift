import Combine
import Foundation
import NetworkExtension
import PelicanKit
import PelicanTunnelProtocol

/// Runs Pelican's network extension, and is the only thing that can.
///
/// What this turns on: macOS offers Pelican the connections made to a short, fixed list of
/// addresses. The extension notes who made each one and then declines it, so the connection
/// goes directly to its destination, untouched. Nothing is decrypted and nothing is rerouted —
/// the gain is that macOS tells Pelican which process a connection belongs to, instead of
/// Pelican having to infer it.
///
/// Three rules this follows, because an active proxy configuration sits in the network path:
///
/// 1. **Narrow by default.** Only the enabled tools' published address ranges are listed. A
///    connection to anything else is never offered to the extension at all.
/// 2. **Never on demand.** The configuration is on-demand-disabled, so it exists only while
///    Pelican is running and asked for it.
/// 3. **Nothing happens without you.** Turning it on is an explicit action, and macOS asks for
///    your permission on top of that.
@MainActor
final class TunnelController: ObservableObject {

    enum State: Equatable {
        case off
        case starting
        case monitoring
        case needsApproval(String)
        case failed(String)

        var line: String {
            switch self {
            case .off: return "Not monitoring."
            case .starting: return "Starting…"
            case .monitoring: return "Monitoring: macOS is naming the process behind each connection."
            case .needsApproval(let what): return what
            case .failed(let why): return why
            }
        }
    }

    @Published private(set) var state: State = .off
    /// Connections the extension has reported, newest first.
    @Published private(set) var observations: [FlowObservation] = []
    /// The extension answered a health check this recently.
    @Published private(set) var lastHeartbeat: Date?

    static let maximumObservations = 2_000

    /// What macOS says the session is doing, for diagnosing a tunnel that will not start.
    var sessionStatus: String {
        guard let session = manager?.connection as? NETunnelProviderSession else { return "no session" }
        switch session.status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    /// Whether macOS has the configuration saved and enabled.
    var configurationSummary: String {
        guard let manager else { return "no configuration" }
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        return "enabled=\(manager.isEnabled) provider=\(proto?.providerBundleIdentifier ?? "—")"
    }
    /// A reserved documentation address (RFC 5737), used to prove the path end to end without
    /// touching anything real.
    static let canaryRange = "203.0.113.1/32:443"

    private var manager: NETransparentProxyManager?
    private var poller: Timer?

    // MARK: - Turning it on and off

    /// Watch these address ranges, in "address/prefix:port" form. Nothing else is offered to
    /// the extension.
    func start(ranges: [String], debugLogging: Bool = false) async {
        guard !ranges.isEmpty else {
            state = .failed("No addresses to watch, so there is nothing to monitor.")
            return
        }
        state = .starting
        do {
            let manager = try await loadOrCreateManager()
            self.manager = manager
            guard let session = manager.connection as? NETunnelProviderSession else {
                state = .failed("macOS did not provide a session for the extension.")
                return
            }
            try session.startTunnel(options: [
                "ranges": ranges as NSArray,
                "debug": NSNumber(value: debugLogging),
            ])
            // Do not claim to be monitoring until macOS says the session is up.
            for _ in 0..<40 where session.status != .connected {
                try? await Task.sleep(for: .milliseconds(250))
                if session.status == .disconnected || session.status == .invalid { break }
            }
            guard session.status == .connected else {
                state = .failed("macOS did not start the session (it is \(sessionStatus)). "
                    + "The first time, it asks for permission to add a proxy configuration.")
                return
            }
            state = .monitoring
            beginPolling(ranges: ranges)
        } catch {
            state = .failed(Self.explain(error))
        }
    }

    func stop() {
        poller?.invalidate()
        poller = nil
        (manager?.connection as? NETunnelProviderSession)?.stopTunnel()
        state = .off
        lastHeartbeat = nil
    }

    /// Forget the configuration entirely, so nothing of it is left in System Settings.
    func removeConfiguration() async {
        stop()
        guard let manager else { return }
        try? await manager.removeFromPreferences()
        self.manager = nil
    }

    private func loadOrCreateManager() async throws -> NETransparentProxyManager {
        let existing = try await NETransparentProxyManager.loadAllFromPreferences()
        let manager = existing.first ?? NETransparentProxyManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelInstaller.extensionIdentifier
        // Required, but unused: nothing is tunnelled anywhere.
        proto.serverAddress = "Pelican"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Pelican"
        manager.isEnabled = true
        // Never started by the system on its own: only while Pelican is running and asked.
        manager.isOnDemandEnabled = false
        try await manager.saveToPreferences()
        // Reload, so the connection object matches what was saved.
        try await manager.loadFromPreferences()
        return manager
    }

    // MARK: - Watching it

    /// Ask the extension what it has seen, and confirm it is still answering. A tunnel that has
    /// stopped answering is stopped rather than left in the path.
    private func beginPolling(ranges: [String]) {
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await send(.setRanges(ranges)) }
    }

    private func poll() async {
        guard case .observations(let seen)? = await send(.drain) else {
            // No answer: if it has been silent for a while, take it out of the path.
            if let last = lastHeartbeat, Date().timeIntervalSince(last) > 15 {
                state = .failed("The extension stopped answering, so monitoring was stopped.")
                stop()
            }
            return
        }
        lastHeartbeat = Date()
        guard !seen.isEmpty else { return }
        observations.insert(contentsOf: seen.reversed(), at: 0)
        if observations.count > Self.maximumObservations {
            observations.removeLast(observations.count - Self.maximumObservations)
        }
    }

    @discardableResult
    private func send(_ request: TunnelRequest) async -> TunnelReply? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected || session.status == .connecting else { return nil }
        return await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ reply: TunnelReply?) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: reply)
            }
            do {
                try session.sendProviderMessage(TunnelCoding.encode(request)) { data in
                    finish(data.flatMap { TunnelCoding.decode(TunnelReply.self, from: $0) })
                }
            } catch {
                finish(nil)
            }
            // The reply handler is not guaranteed to be called.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if (error as NSError).domain == NEVPNErrorDomain {
            return "macOS would not save the configuration: \(text). It asks for permission the first time."
        }
        return text
    }
}
