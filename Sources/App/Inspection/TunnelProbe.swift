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
        case "status":
            break
        default:
            print("\nUnknown action '\(action)'. Use status, install or remove.")
        }

        print("\nWhat macOS reports (`systemextensionsctl list`):")
        for line in systemExtensions() { print("  \(line)") }
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
