import Foundation
import PelicanKit

/// `Pelican --tunnel status|install|remove`
///
/// Drives the network extension from the command line, so packaging, signing and approval can
/// be checked before any of it is wired into the interface.
@MainActor
enum TunnelProbe {

    static func run(_ action: String) async {
        print("Pelican tunnel · \(BuildInfo.current.line)")
        print(String(repeating: "─", count: 72))
        status()

        switch action {
        case "install":
            print("\nAsking macOS to install the extension…")
            let outcome = await TunnelInstaller().install()
            print("  \(outcome.line)")
            if outcome == .needsApproval {
                print("  Approve it, then run `--tunnel status` to confirm.")
            }
        case "remove":
            print("\nAsking macOS to remove the extension…")
            print("  \(await TunnelInstaller().remove().line)")
        case "canary":
            await canary()
        case "hold":
            await hold()
        case "stop":
            let controller = TunnelController()
            await controller.removeConfiguration()
            print("\nStopped and removed the monitoring configuration.")
        case "status":
            break
        default:
            print("\nUnknown action '\(action)'. Use status, install or remove.")
        }

        print("\nWhat macOS reports (`systemextensionsctl list`):")
        for line in systemExtensions() { print("  \(line)") }
    }

    /// Start a session on the canary address and keep it open, so the extension process and
    /// its log output can be inspected from outside.
    private static func hold() async {
        let controller = TunnelController()
        print("\nHolding a session on \(TunnelController.canaryRange) for 30s…")
        await controller.start(ranges: [TunnelController.canaryRange], debugLogging: true)
        print("  session: \(controller.sessionStatus) — \(controller.state.line)")
        for second in 1...30 {
            try? await Task.sleep(for: .seconds(1))
            if second % 10 == 0 {
                print("  \(second)s: session=\(controller.sessionStatus) "
                    + "heartbeat=\(controller.lastHeartbeat != nil ? "yes" : "no") "
                    + "seen=\(controller.observations.count)")
            }
        }
        await controller.removeConfiguration()
        print("  stopped and removed the configuration")
    }

    /// Start monitoring, but watching only a reserved documentation address (RFC 5737) that
    /// nothing on this Mac uses. Proves the whole path — configuration, session, the extension
    /// seeing a connection and declining it — without any real traffic being involved.
    private static func canary() async {
        let controller = TunnelController()
        print("\nStarting a session that watches only \(TunnelController.canaryRange)…")
        await controller.start(ranges: [TunnelController.canaryRange], debugLogging: true)
        print("  configuration: \(controller.configurationSummary)")
        print("  session:       \(controller.sessionStatus)")
        print("  \(controller.state.line)")
        guard controller.state == .monitoring else {
            print("\n  Leaving the configuration in place so it can be inspected.")
            print("  Remove it with: Pelican --tunnel stop")
            return
        }

        print("  connecting to the canary address (nothing is listening; it should just fail)…")
        let reached = await connect(host: "203.0.113.1", port: 443, timeout: 3)
        print("  connection result: \(reached)")

        // Give the extension a moment to report it.
        for _ in 0..<10 where controller.observations.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
        }
        if controller.observations.isEmpty {
            print("  the extension reported nothing — the rule may not have matched")
        } else {
            for seen in controller.observations.prefix(3) {
                print("  saw: pid \(seen.pid) \(seen.signingIdentifier.isEmpty ? "(unsigned)" : seen.signingIdentifier) → \(seen.remoteAddress):\(seen.remotePort)")
            }
        }
        print("  heartbeat: \(controller.lastHeartbeat != nil ? "answering" : "no reply")")

        await controller.removeConfiguration()
        print("  stopped and removed the configuration")
    }

    /// A plain TCP connect, to generate one connection to the canary address.
    private static func connect(host: String, port: UInt16, timeout: Int) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let socketHandle = socket(AF_INET, SOCK_STREAM, 0)
                guard socketHandle >= 0 else {
                    continuation.resume(returning: "could not open a socket"); return
                }
                defer { close(socketHandle) }
                var timeval = timeval(tv_sec: timeout, tv_usec: 0)
                setsockopt(socketHandle, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                inet_pton(AF_INET, host, &address.sin_addr)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                continuation.resume(returning: result == 0 ? "connected" : "failed (\(String(cString: strerror(errno))))")
            }
        }
    }

    private static func status() {
        let bundle = Bundle.main.bundleURL
        print("running from: \(tilde(bundle.path))")
        if let blocker = TunnelInstaller.blocker {
            print("not installable here:")
            print("  \(blocker)")
        } else {
            print("installable:  yes — the extension is bundled and Pelican is in /Applications")
        }
    }

    /// What the OS itself says, rather than what Pelican believes.
    private static func systemExtensions() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ["could not run systemextensionsctl: \(error)"] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { PrivateDetails.maskTeamIdentifiers(String($0)) }
        return text.isEmpty ? ["(no output)"] : text
    }

    private static func tilde(_ path: String) -> String { PrivateDetails.tilde(path) }
}
