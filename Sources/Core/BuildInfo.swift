import Foundation

/// Pelican's own version and provenance, from its Info.plist. make-app.sh stamps the commit
/// and build date into the bundle; `swift run` reads the plist embedded in the binary
/// (Package.swift, -sectcreate) and has no commit.
struct BuildInfo: Sendable, Equatable {
    let version: String
    let build: String
    let commit: String?
    let builtAt: String?

    static let current = BuildInfo(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "dev"
        build = info["CFBundleVersion"] as? String ?? "0"
        commit = info["PelicanBuildCommit"] as? String
        builtAt = info["PelicanBuildDate"] as? String
    }

    /// "Pelican 0.2.0 (1) · 1a2b3c4d5e6f" (with "-dirty" when built from uncommitted work), or
    /// "· from source" when unstamped. make-app.sh stamps the short commit, so it is shown whole.
    var line: String {
        "Pelican \(version) (\(build)) · \(commit ?? "from source")"
    }

    /// Running as an assembled .app (notifications and login items need one).
    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
}
