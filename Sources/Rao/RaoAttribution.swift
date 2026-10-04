import Foundation
import PelicanKit

/// Why Pelican believes a process belongs to a Rao app.
struct RaoAttribution: Sendable, Hashable, Codable {
    enum Role: Sendable, Hashable, Codable {
        case app
        case helper(String)
    }

    /// Strongest first when compared.
    enum Confidence: Int, Sendable, Codable, Comparable {
        case processName = 0   // only the name matches — an impostor candidate
        case portAffinity      // a helper's name, holding one of the app's loopback ports
        case childOfApp        // a helper's name, started by the app
        case path              // lives where the app installs it
        case bundle            // inside the app's bundle
        case signature         // signed with the app's (or a helper's) identifier
        case delegated         // a system daemon's socket, opened on behalf of an attributed process

        static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    }

    var role: Role
    var confidence: Confidence
    var evidence: String

    var processName: String {
        switch role {
        case .app: return "app"
        case .helper(let name): return name
        }
    }

    func roleName(in app: RaoApp) -> String {
        switch role {
        case .app: return app.executableName
        case .helper(let name): return name
        }
    }
}

enum RaoAttributor {

    /// Pure. `appPids` are processes already attributed as the app itself; `touchesKnownPorts`
    /// is whether this process holds a flow on one of the app's loopback ports.
    static func attribute(
        name: String,
        identity: ProcessIdentity?,
        parentPid: Int32?,
        appPids: Set<Int32>,
        touchesKnownPorts: Bool,
        app: RaoApp
    ) -> RaoAttribution? {
        let helperNames = Set(app.helpers.map(\.processName))

        if let identifier = identity?.signature?.identifier {
            if identifier == app.bundleIdentifier {
                return .init(role: .app, confidence: .signature, evidence: "signed as \(identifier)")
            }
            if let helper = app.helper(signedAs: identifier) {
                return .init(role: .helper(helper.processName), confidence: .signature, evidence: "signed as \(identifier)")
            }
        }
        if let identity, identity.bundleIdentifier == app.bundleIdentifier, let bundle = identity.bundlePath {
            let role: RaoAttribution.Role = name == app.executableName ? .app : .helper(name)
            return .init(role: role, confidence: .bundle, evidence: "inside \(bundle)")
        }
        if let path = identity?.executablePath, let processName = app.processName(atPath: path) {
            let role: RaoAttribution.Role = processName == app.executableName ? .app : .helper(processName)
            return .init(role: role, confidence: .path, evidence: "runs from \(path)")
        }
        if helperNames.contains(name), let parentPid, appPids.contains(parentPid) {
            return .init(role: .helper(name), confidence: .childOfApp, evidence: "started by \(app.name) (pid \(parentPid))")
        }
        if helperNames.contains(name), touchesKnownPorts {
            return .init(role: .helper(name), confidence: .portAffinity,
                         evidence: "named \(name) and holding one of \(app.name)'s local ports")
        }
        if name == app.executableName {
            return .init(role: .app, confidence: .processName, evidence: "named \(name) — nothing else matches")
        }
        return nil
    }
}
