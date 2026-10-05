import Foundation
import NetworkExtension
import PelicanTunnelProtocol
import os

/// Pelican's network system extension.
///
/// macOS runs this as root, so it is kept deliberately small and dull. Besides the shared
/// protocol it links nothing but system frameworks: no TLS, no parsers, no storage, no
/// third-party code.
///
/// **It observes; it does not interfere.** Every connection macOS offers is noted and then
/// *declined*. Apple documents that returning `false` from `handleNewFlow` lets the connection
/// "proceed to communicate directly with the flow's ultimate destination" — so the traffic is
/// untouched, exactly as if no proxy were installed. Nothing is decrypted and nothing is
/// rerouted.
///
/// What it adds over watching from outside is identity: macOS hands the flow the source
/// process and its signing identifier, which is a far better answer than guessing from a pid
/// that may already be gone.
///
/// Every path that is unsure, unconfigured or broken also ends in `false`.
@objc(PelicanTunnelProvider)
final class PelicanTunnelProvider: NETransparentProxyProvider {

    private let log = Logger(subsystem: "nyc.rao.pelican.tunnel", category: "provider")
    private let seen = Observations()
    /// Off unless the app asks for it. A root process should not be writing a log file during
    /// ordinary use.
    private var debugLogging = false

    /// Started only by Pelican itself, never on demand: if the app is not running to ask for
    /// it, the tunnel should not exist.
    ///
    /// The completion-handler forms are overridden rather than the `async` ones: these are the
    /// selectors macOS actually calls, and an `async` override of them is not guaranteed to be
    /// found.
    override func startProxy(options: [String: Any]?,
                             completionHandler: @escaping (Error?) -> Void) {
        let ranges = (options?["ranges"] as? [String]) ?? []
        debugLogging = (options?["debug"] as? Bool) ?? false
        note("startProxy: watching \(ranges.count) range(s), declining every flow")
        apply(ranges: ranges) { error in
            if let error { self.note("startProxy failed: \(error)") }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason,
                            completionHandler: @escaping () -> Void) {
        note("stopProxy: \(reason.rawValue)")
        Task {
            await seen.removeAll()
            completionHandler()
        }
    }

    /// Note the connection, then decline it so macOS connects it directly.
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let metadata = flow.metaData
        let pid = Self.pid(from: metadata.sourceAppAuditToken)
        // Pelican's own traffic is never reported back to Pelican.
        if pid == getpid() { return false }

        let remote = Self.endpoint(of: flow)
        let observation = FlowObservation(
            pid: pid,
            signingIdentifier: metadata.sourceAppSigningIdentifier,
            remoteHost: flow.remoteHostname,
            remoteAddress: remote.address,
            remotePort: remote.port,
            isOutbound: true,
            at: Date())
        note("flow: pid \(pid) → \(remote.address):\(remote.port) — declined")
        Task { await seen.add(observation) }

        // Always: the connection proceeds directly to its real destination.
        return false
    }

    /// The app asks for what has been seen, and tells the extension what to watch.
    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)? = nil) {
        guard let request = TunnelCoding.decode(TunnelRequest.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        switch request {
        case .ping:
            completionHandler?(TunnelCoding.encode(TunnelReply.pong))
        case .drain:
            Task {
                let taken = await seen.take()
                completionHandler?(TunnelCoding.encode(TunnelReply.observations(taken)))
            }
        case .setRanges(let ranges):
            apply(ranges: ranges) { _ in
                completionHandler?(TunnelCoding.encode(TunnelReply.ok))
            }
        }
    }

    // MARK: - What to watch

    /// Only connections to these addresses are offered to the extension at all. Everything else
    /// never reaches it, so a fault here cannot touch the rest of the Mac's networking.
    private func apply(ranges: [String], completion: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let rules = ranges.compactMap { Self.rule(for: $0) }
        note("applying \(rules.count) rule(s) from \(ranges.count) range(s)")
        settings.includedNetworkRules = rules
        setTunnelNetworkSettings(settings) { error in completion(error) }
    }

    /// Always to os_log; to a file only when the app asked for diagnostics, and then into a
    /// directory only root can write, never a world-writable one.
    static let debugLogPath = "/var/log/pelican-tunnel.log"

    private func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
        guard debugLogging else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: Self.debugLogPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: Self.debugLogPath, atomically: true, encoding: .utf8)
        }
    }

    /// "address/prefix:port" — a rule matching outbound TCP to one network.
    static func rule(for text: String) -> NENetworkRule? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { return nil }
        let network = parts[0].split(separator: "/")
        guard let address = network.first.map(String.init) else { return nil }
        let prefix = network.count > 1 ? Int(network[1]) ?? 32 : 32
        let endpoint = NWHostEndpoint(hostname: address, port: String(port))
        return NENetworkRule(remoteNetwork: endpoint, remotePrefix: prefix,
                             localNetwork: nil, localPrefix: 0,
                             protocol: .TCP, direction: .outbound)
    }

    // MARK: - Reading the flow

    private static func pid(from token: Data?) -> Int32 {
        guard let token, token.count == MemoryLayout<audit_token_t>.size else { return 0 }
        return token.withUnsafeBytes { raw in
            audit_token_to_pid(raw.loadUnaligned(as: audit_token_t.self))
        }
    }

    private static func endpoint(of flow: NEAppProxyFlow) -> (address: String, port: Int) {
        guard let tcp = flow as? NEAppProxyTCPFlow else { return ("", 0) }
        if let host = tcp.remoteEndpoint as? NWHostEndpoint {
            return (host.hostname, Int(host.port) ?? 0)
        }
        return ("", 0)
    }
}

/// The connections seen since the app last asked, bounded so a busy minute cannot grow without
/// limit in a root process.
private actor Observations {
    private var items: [FlowObservation] = []
    static let limit = 2_000

    func add(_ observation: FlowObservation) {
        items.append(observation)
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
    }

    func take() -> [FlowObservation] {
        defer { items = [] }
        return items
    }

    func removeAll() { items = [] }
}
