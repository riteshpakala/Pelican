import Foundation
import PelicanKit

/// The consent the user has given an app, as far as network use goes.
enum ConsentMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case onDevice
    case signedIn
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: return "On-device"
        case .signedIn: return "Signed in"
        case .unknown: return "Unknown"
        }
    }
}

struct LoopbackPort: Sendable, Hashable {
    let port: UInt16
    let label: String
}

/// A process an app runs besides its main executable.
struct RaoHelper: Sendable, Hashable {
    let processName: String
    let signingIdentifier: String
    /// Other identifiers a legitimate copy may carry (a helper shared between apps).
    let alternateIdentifiers: [String]
    /// Absolute ("~/…" allowed) or bundle-relative ("Ambient.app/Contents/Helpers/thread").
    let pathHints: [String]
    let shared: Bool
    let note: String
}

/// A host an app is known to contact, and when that is within the user's consent.
struct ExpectedHost: Sendable, Hashable, Identifiable {
    enum Pattern: Sendable, Hashable {
        case exact(String)
        case suffix(String)
        /// Any external host on port 443 — only for broad, consented behaviour such as
        /// fetching the pictures on a page being read.
        case anyHTTPS
    }

    let pattern: Pattern
    /// nil = any of the app's processes.
    let processes: Set<String>?
    let modes: Set<ConsentMode>
    let purpose: String
    /// Happens once (a model download), not every day.
    let firstRunOnly: Bool
    /// Matches much more than one service; shown with its own badge.
    let broad: Bool
    /// A boolean in the app's saved settings that must not be off for this to be consented.
    let requiresSetting: String?
    /// Hostnames to resolve so connections to their addresses can be recognised.
    let resolve: [String]

    var id: String { displayPattern + "|" + (processes?.sorted().joined(separator: ",") ?? "*") }

    var displayPattern: String {
        switch pattern {
        case .exact(let host): return host
        case .suffix(let domain): return "*." + domain
        case .anyHTTPS: return "any site (HTTPS)"
        }
    }

    /// The first candidate hostname this rule matches, or nil.
    func match(candidates: [String], remotePort: UInt16?) -> String? {
        switch pattern {
        case .exact(let host):
            return candidates.first { $0.caseInsensitiveCompare(host) == .orderedSame }
        case .suffix(let domain):
            let lower = domain.lowercased()
            return candidates.first {
                let candidate = $0.lowercased()
                return candidate == lower || candidate.hasSuffix("." + lower)
            }
        case .anyHTTPS:
            return remotePort == 443 ? (candidates.first ?? "") : nil
        }
    }
}

/// A saved setting worth showing on the consent card.
struct ConsentSetting: Sendable, Hashable {
    let key: String
    let label: String
}

/// Where an app keeps its own settings, so Pelican can read the consent mode the user chose
/// instead of asking. Read-only; Pelican never writes another app's files.
struct ConsentStore: Sendable, Hashable {
    /// Directory ("~/…" allowed) and file-name prefix; the newest matching file wins.
    let directory: String
    let filePrefix: String
    /// Path of dictionary keys to the settings dictionary inside the property list.
    let statePath: [String]
    /// Boolean key: true = on-device, false = signed in.
    let onDeviceKey: String
    let settings: [ConsentSetting]
}

/// One of Rao's apps, as Pelican watches it. Every value here is a product fact the app's own
/// source and site state; none identifies a signing certificate or team.
package struct RaoApp: Identifiable, Sendable, Hashable {
    enum Availability: Sendable, Hashable { case available, comingSoon }

    package let id: String
    package let name: String
    let tagline: String
    let availability: Availability
    let siteURL: URL
    let bundleIdentifier: String
    let executableName: String
    let helpers: [RaoHelper]
    let installPathHints: [String]
    let loopbackPorts: [LoopbackPort]
    let expectedHosts: [ExpectedHost]
    let consentStore: ConsentStore?
    /// The consent boundary in one plain sentence, per mode.
    let boundary: [ConsentMode: String]

    var processNames: Set<String> { Set([executableName] + helpers.map(\.processName)) }

    var signingIdentifiers: Set<String> {
        Set([bundleIdentifier] + helpers.flatMap { [$0.signingIdentifier] + $0.alternateIdentifiers })
    }

    func helper(named name: String) -> RaoHelper? {
        helpers.first { $0.processName == name }
    }

    func helper(signedAs identifier: String) -> RaoHelper? {
        helpers.first { $0.signingIdentifier == identifier || $0.alternateIdentifiers.contains(identifier) }
    }

    func loopbackLabel(_ port: UInt16?) -> String? {
        guard let port else { return nil }
        return loopbackPorts.first { $0.port == port }?.label
    }

    /// Every hostname to forward-resolve for this app.
    var hostnamesToResolve: [String] {
        Array(Set(expectedHosts.flatMap(\.resolve))).sorted()
    }

    /// Whether an executable path is where this app (or one of its helpers) lives.
    /// Returns the process name it would be.
    func processName(atPath path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func expand(_ hint: String) -> String {
            hint.hasPrefix("~/") ? home + hint.dropFirst() : hint
        }
        func matches(_ hint: String) -> Bool {
            let expanded = expand(hint)
            return expanded.hasPrefix("/") ? path == expanded : path.hasSuffix("/" + expanded)
        }
        let appHints = installPathHints.map { expand($0) + "/Contents/MacOS/" + executableName }
            + ["\(name).app/Contents/MacOS/\(executableName)"]
        if appHints.contains(where: matches) { return executableName }
        for helper in helpers where helper.pathHints.contains(where: matches) {
            return helper.processName
        }
        return nil
    }
}

extension RaoApp {
    static let all: [RaoApp] = [.ambient, .craft, .veil]

    /// Ambient (ambient.rao.nyc): reads along with you and listens for "Hey Mary". Product
    /// facts only: its identifiers, its helpers and where they run from, its loopback ports,
    /// what on-device mode turns off, and the hosts each service contacts.
    static let ambient = RaoApp(
        id: "ambient",
        name: "Ambient",
        tagline: "Intelligent marginalia for everything.",
        availability: .available,
        siteURL: URL(string: "https://ambient.rao.nyc")!,
        bundleIdentifier: "nyc.rao.ambient",
        executableName: "Ambient",
        helpers: [
            RaoHelper(
                processName: "sewn-server",
                signingIdentifier: "nyc.rao.ambient.sewn-server",
                alternateIdentifiers: ["nyc.rao.craft.sewn-server", "nyc.rao.veil.sewn-server"],
                pathHints: ["~/.rao/sewn/bin/sewn-server", "Ambient.app/Contents/Helpers/sewn-server"],
                shared: true,
                note: "Sewn, the local model server. Shared with Rao's other apps: one of them may start it, and it can outlive Ambient."
            ),
            RaoHelper(
                processName: "thread",
                signingIdentifier: "nyc.rao.ambient.thread",
                alternateIdentifiers: [],
                pathHints: ["Ambient.app/Contents/Helpers/thread"],
                shared: false,
                note: "Thread, Ambient's local memory server."
            ),
        ],
        installPathHints: ["/Applications/Ambient.app", "~/Applications/Ambient.app"],
        loopbackPorts: [
            LoopbackPort(port: 47080, label: "Sewn (HTTP)"),
            LoopbackPort(port: 47091, label: "Sewn (gRPC)"),
            LoopbackPort(port: 47081, label: "Thread (HTTP)"),
            LoopbackPort(port: 47090, label: "Thread (gRPC)"),
        ],
        expectedHosts: [
            ExpectedHost(
                pattern: .suffix("huggingface.co"), processes: ["sewn-server"], modes: [.onDevice, .signedIn],
                purpose: "Sewn downloads its on-device model from HuggingFace, once",
                firstRunOnly: true, broad: false, requiresSetting: nil,
                resolve: ["huggingface.co", "cdn-lfs.huggingface.co", "cdn-lfs-us-1.huggingface.co"]),
            ExpectedHost(
                pattern: .suffix("hf.co"), processes: ["sewn-server"], modes: [.onDevice, .signedIn],
                purpose: "Sewn downloads its on-device model from HuggingFace, once",
                firstRunOnly: true, broad: false, requiresSetting: nil,
                resolve: ["hf.co", "cdn-lfs.hf.co", "cdn-lfs-us-1.hf.co", "cas-bridge.xethub.hf.co",
                          "cas-server.xethub.hf.co", "transfer.xethub.hf.co"]),
            ExpectedHost(
                pattern: .suffix("cloudfront.net"), processes: ["sewn-server"], modes: [.onDevice, .signedIn],
                purpose: "HuggingFace serves model files through CloudFront (recognised by reverse DNS)",
                firstRunOnly: true, broad: true, requiresSetting: nil, resolve: []),
            ExpectedHost(
                pattern: .exact("supabase.seer.services"), processes: nil, modes: [.signedIn],
                purpose: "Your Ambient account: sign-in, plan and keys",
                firstRunOnly: false, broad: false, requiresSetting: nil,
                resolve: ["supabase.seer.services"]),
            ExpectedHost(
                pattern: .exact("api.mistral.ai"), processes: ["sewn-server", "thread"], modes: [.signedIn],
                purpose: "Mistral: hosted replies, voice, picture descriptions and memory",
                firstRunOnly: false, broad: false, requiresSetting: nil,
                resolve: ["api.mistral.ai"]),
            ExpectedHost(
                pattern: .exact("news.google.com"), processes: ["Ambient"], modes: [.signedIn],
                purpose: "News briefs (Ambient Plus)",
                firstRunOnly: false, broad: false, requiresSetting: nil,
                resolve: ["news.google.com"]),
            ExpectedHost(
                pattern: .anyHTTPS, processes: ["Ambient"], modes: [.signedIn],
                purpose: "Pictures on the pages you read, fetched so they can be described",
                firstRunOnly: false, broad: true, requiresSetting: "describeImagesThroughSewn",
                resolve: []),
        ],
        consentStore: ConsentStore(
            directory: "~/Library/Application Support/nyc.rao.ambient/granite-db",
            filePrefix: "ambient.persistence.config.",
            statePath: ["state"],
            onDeviceKey: "onDeviceMode",
            settings: [
                ConsentSetting(key: "onDeviceMode", label: "On-device mode"),
                ConsentSetting(key: "alwaysListeningEnabled", label: "Always listening (\u{201C}Hey Mary\u{201D})"),
                ConsentSetting(key: "autoListenOnSummon", label: "Listen when summoned"),
                ConsentSetting(key: "describeImagesThroughSewn", label: "Describe pictures"),
                ConsentSetting(key: "ambientCorpusIndexing", label: "Remember what you read"),
                ConsentSetting(key: "llmEngine", label: "Reply engine"),
                ConsentSetting(key: "sewnTransport", label: "Transport"),
                ConsentSetting(key: "excludedBundleIDs", label: "Apps Ambient never reads"),
            ]),
        boundary: [
            .onDevice: "Replies and speech stay on this Mac. Nothing leaves it except Sewn's one-time model download.",
            .signedIn: "Signed in, Ambient may also reach your account, Mistral for hosted replies and voice, Google News, and the pictures on pages you read.",
            .unknown: "Pelican couldn't read Ambient's mode, so it holds Ambient to the on-device rules.",
        ]
    )

    static let craft = RaoApp(
        id: "craft", name: "Craft", tagline: "A coding agent that runs entirely on your Mac.",
        availability: .comingSoon, siteURL: URL(string: "https://craft.rao.nyc")!,
        bundleIdentifier: "nyc.rao.craft", executableName: "Craft", helpers: [], installPathHints: [],
        loopbackPorts: [], expectedHosts: [], consentStore: nil, boundary: [:])

    static let veil = RaoApp(
        id: "veil", name: "Veil", tagline: "Describes images, so a language model can understand them.",
        availability: .comingSoon, siteURL: URL(string: "https://rao.nyc")!,
        bundleIdentifier: "nyc.rao.veil", executableName: "Veil", helpers: [], installPathHints: [],
        loopbackPorts: [], expectedHosts: [], consentStore: nil, boundary: [:])
}
