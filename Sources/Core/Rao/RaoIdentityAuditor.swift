import Foundation

struct RaoFinding: Sendable, Hashable, Codable, Identifiable {
    enum Severity: String, Sendable, Codable, Comparable {
        case verified, info, warning, alarm

        private var rank: Int {
            switch self {
            case .verified: return 0
            case .info: return 1
            case .warning: return 2
            case .alarm: return 3
            }
        }
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    var severity: Severity
    var title: String
    var detail: String

    var id: String { severity.rawValue + "|" + title }
}

/// A running process Pelican attributes to a Rao app.
struct RaoProcess: Sendable, Equatable, Identifiable, Codable {
    var pid: Int32
    var name: String
    var attribution: RaoAttribution
    var identity: ProcessIdentity?
    var parentName: String?
    var id: Int32 { pid }
}

/// The copy of the app installed where it installs itself, read from disk. When it is a
/// notarized Developer ID release, every running process that claims to be the app is held
/// to its signer — no team ID needs to be written into Pelican.
struct InstalledReference: Sendable, Equatable, Codable {
    var path: String
    var version: String?
    var build: String?
    var signature: CodeSignature?

    var isRelease: Bool {
        guard let signature else { return false }
        return signature.isValid && signature.leafKind == .developerID && signature.hardenedRuntime
            && signature.notarized == true && signature.teamIdentifier != nil
    }

    static func read(app: RaoApp) -> InstalledReference? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for hint in app.installPathHints {
            let path = hint.hasPrefix("~/") ? home + hint.dropFirst() : hint
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let info = ProcessIdentity.bundleInfo(bundlePath: path)
            return InstalledReference(
                path: path,
                version: info?["CFBundleShortVersionString"] as? String,
                build: info?["CFBundleVersion"] as? String,
                signature: CodeSignature.read(path: path))
        }
        return nil
    }
}

/// Generic identity rules. Nothing here names a team or certificate: it compares what macOS
/// reports about the running processes with each other, with the app's published bundle and
/// helper identifiers, and with the installed release.
enum RaoIdentityAuditor {

    static func audit(app: RaoApp, processes: [RaoProcess], reference: InstalledReference?) -> [RaoFinding] {
        var findings: [RaoFinding] = []
        let releaseTeam = reference?.isRelease == true ? reference?.signature?.teamIdentifier : nil
        let appPids = Set(processes.filter { $0.attribution.role == .app }.map(\.pid))

        if let reference {
            findings.append(referenceFinding(reference, app: app))
        }

        for process in processes {
            let label = "\(process.name) (pid \(process.pid))"
            guard let identity = process.identity else {
                findings.append(.init(severity: .warning, title: "Couldn't read \(process.name)",
                                      detail: "\(label) exited or macOS withheld its details, so its identity is unchecked."))
                continue
            }
            guard let signature = identity.signature else {
                findings.append(.init(severity: .warning, title: "\(process.name) has no readable signature",
                                      detail: "macOS returned no code signature for \(label)."))
                continue
            }
            if !signature.isValid {
                findings.append(.init(severity: .alarm, title: "\(process.name)'s signature doesn't validate",
                                      detail: "\(label): \(signature.validityError ?? "invalid"). The code may have been modified."))
                continue
            }

            let expectedIDs: [String]
            switch process.attribution.role {
            case .app: expectedIDs = [app.bundleIdentifier]
            case .helper(let name):
                let helper = app.helper(named: name)
                expectedIDs = helper.map { [$0.signingIdentifier] + $0.alternateIdentifiers } ?? []
            }
            let identifier = signature.identifier ?? "nothing"
            var flaggedIdentity = false
            if !expectedIDs.isEmpty, !expectedIDs.contains(identifier) {
                flaggedIdentity = true
                let from = identity.executablePath.map { " It runs from \($0)." } ?? ""
                if process.attribution.role == .app {
                    findings.append(.init(severity: .alarm, title: "A process named \(process.name) isn't signed as \(app.bundleIdentifier)",
                                          detail: "\(label) is signed as \u{201C}\(identifier)\u{201D}.\(from) Something may be posing as \(app.name)."))
                } else if signature.isDevelopmentBuild && releaseTeam == nil {
                    findings.append(.init(severity: .warning, title: "\(process.name) is an unsigned development build",
                                          detail: "\(label) is signed as \u{201C}\(identifier)\u{201D}, not \(expectedIDs[0]); Pelican ties it to \(app.name) because it is \(process.attribution.evidence).\(from) Expected only when Rao's apps run from source."))
                } else {
                    findings.append(.init(severity: .alarm, title: "\(process.name) isn't signed as \(expectedIDs[0])",
                                          detail: "\(label) is signed as \u{201C}\(identifier)\u{201D}.\(from)"))
                }
            }

            if let releaseTeam, signature.teamIdentifier != releaseTeam {
                flaggedIdentity = true
                let signer = signature.leafSubject ?? (signature.isAdHoc ? "no certificate (ad-hoc)" : "unknown")
                findings.append(.init(severity: .alarm, title: "\(process.name) is signed by someone other than the installed \(app.name)",
                                      detail: "The installed \(app.name) is signed by \(reference?.signature?.leafSubject ?? "its developer"); \(label) is signed by \(signer)."))
                continue
            }

            if signature.isDevelopmentBuild {
                if !flaggedIdentity {
                    findings.append(.init(severity: .warning, title: "\(process.name) is a development build",
                                          detail: "\(label) is \(signature.developmentReasons.joined(separator: ", ")). Its identity can't be tied to a notarized release."))
                }
            } else if !flaggedIdentity {
                if signature.notarized == true {
                    findings.append(.init(severity: .verified, title: "\(process.name) verified",
                                          detail: "Signed as \(identifier) by \(signature.leafSubject ?? "its developer"), hardened runtime, notarized by Apple."))
                } else {
                    findings.append(.init(severity: .warning, title: "\(process.name) isn't notarized",
                                          detail: "\(label) is signed by \(signature.leafSubject ?? "its developer") with hardened runtime, but Apple hasn't notarized this build."))
                }
            }
        }

        // One developer signs every process of a release.
        let teams = Set(processes.compactMap { $0.identity?.signature?.teamIdentifier })
        if releaseTeam == nil, teams.count > 1 {
            let anyDevelopment = processes.contains { $0.identity?.signature?.isDevelopmentBuild ?? true }
            let list = processes.compactMap { p -> String? in
                guard let team = p.identity?.signature?.teamIdentifier else { return nil }
                return "\(p.name): \(team)"
            }.joined(separator: ", ")
            findings.append(.init(severity: anyDevelopment ? .warning : .alarm,
                                  title: "\(app.name)'s processes are signed by different developers",
                                  detail: list + (anyDevelopment ? ". Some are development builds." : ".")))
        }

        let appPaths = Set(processes.filter { $0.attribution.role == .app }.compactMap { $0.identity?.executablePath })
        if appPaths.count > 1 {
            findings.append(.init(severity: .alarm, title: "Two copies of \(app.name) are running",
                                  detail: appPaths.sorted().joined(separator: " and ")))
        }

        for process in processes where process.attribution.role == .app {
            if let identity = process.identity, identity.bundlePath == nil, let path = identity.executablePath {
                findings.append(.init(severity: .info, title: "\(app.name) is running from source", detail: path))
            }
        }

        for process in processes {
            guard case .helper(let name) = process.attribution.role, let helper = app.helper(named: name), helper.shared,
                  let parent = process.identity?.parentPid, !appPids.contains(parent) else { continue }
            let starter = parent == 1 ? "it outlived the app that started it" : "started by \(process.parentName ?? "pid \(parent)")"
            findings.append(.init(severity: .info, title: "\(name) is running on its own", detail: "\(starter.prefix(1).uppercased() + starter.dropFirst()). \(helper.note)"))
        }
        return findings
    }

    private static func referenceFinding(_ reference: InstalledReference, app: RaoApp) -> RaoFinding {
        let version = [reference.version, reference.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        guard let signature = reference.signature else {
            return .init(severity: .warning, title: "The installed \(app.name) has no readable signature", detail: reference.path)
        }
        if !signature.isValid {
            return .init(severity: .alarm, title: "The installed \(app.name) doesn't validate",
                         detail: "\(reference.path): \(signature.validityError ?? "invalid"). It may have been modified.")
        }
        if signature.identifier != app.bundleIdentifier {
            return .init(severity: .alarm, title: "The installed \(app.name) isn't signed as \(app.bundleIdentifier)",
                         detail: "\(reference.path) is signed as \u{201C}\(signature.identifier ?? "nothing")\u{201D}.")
        }
        if reference.isRelease {
            return .init(severity: .verified, title: "Installed \(app.name) \(version) is a notarized release",
                         detail: "\(reference.path), signed by \(signature.leafSubject ?? "its developer"). Every running \(app.name) process is compared with it.")
        }
        return .init(severity: .warning, title: "The installed \(app.name) isn't a notarized release",
                     detail: "\(reference.path) is \(signature.developmentReasons.isEmpty ? "not notarized" : signature.developmentReasons.joined(separator: ", ")).")
    }
}
