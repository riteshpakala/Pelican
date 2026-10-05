import Foundation
import NetworkExtension
import os

/// Pelican's network system extension.
///
/// macOS runs this as root, so it is kept deliberately small and dull. It has no TLS, no
/// parsers, no storage and no third-party code: its whole job is to look at a connection and
/// decide whether to hand it to the engine — which runs as you, in the app — or to decline it.
///
/// **Declining is the safe answer, and the default.** Apple documents that returning `false`
/// from `handleNewFlow` lets the connection "proceed to communicate directly with the flow's
/// ultimate destination", exactly as if no proxy were installed. So every path that is unsure,
/// unconfigured or broken ends in `false`.
///
/// This first version declines everything. It exists to prove that the bundle builds, signs,
/// activates and removes cleanly, and that a declined connection is genuinely untouched,
/// before any traffic logic is added.
@objc(PelicanTunnelProvider)
final class PelicanTunnelProvider: NETransparentProxyProvider {

    private let log = Logger(subsystem: "nyc.rao.pelican.tunnel", category: "provider")

    /// Started only by Pelican itself, never on demand: if the app is not running to ask for
    /// it, the tunnel should not exist.
    override func startProxy(options: [String: Any]?) async throws {
        log.notice("startProxy: declining every flow in this build")

        // Nothing is matched yet, so nothing is diverted. Later this carries the addresses of
        // the tools the user turned inspection on for.
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = []

        try await setTunnelNetworkSettings(settings)
    }

    override func stopProxy(with reason: NEProviderStopReason) async {
        log.notice("stopProxy: \(reason.rawValue, privacy: .public)")
    }

    /// Every connection macOS offers, declined. The OS then connects it directly.
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        false
    }

    /// Answers the app's health checks, so it can tell a live extension from a stuck one.
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let message = String(data: messageData, encoding: .utf8) else { return nil }
        switch message {
        case "ping":
            return Data("alive".utf8)
        default:
            return nil
        }
    }
}
