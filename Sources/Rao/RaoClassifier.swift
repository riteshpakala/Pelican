import Foundation
import PelicanKit

enum FlowClassKind: String, Sendable, Codable, CaseIterable {
    case local, expected, unexpected
}

/// Whether a connection stayed within the user's consent, and why.
struct FlowClassification: Sendable, Equatable, Codable {
    var kind: FlowClassKind
    var note: String
    var matchedHost: String? = nil
    var broad: Bool = false
    var firstRun: Bool = false
    var unknownLoopbackPort: Bool = false
    /// Judged under on-device rules because the mode could not be read.
    var modeWasUnknown: Bool = false
}

/// The facts about one connection that classification needs.
struct FlowFacts: Sendable {
    var process: String            // the Rao role name: "Ambient", "sewn-server", …
    var proto: FlowProto
    var direction: FlowDirection
    var scope: FlowScope
    var localAddress: String
    var localPort: UInt16?
    var remoteAddress: String
    var remotePort: UInt16?
    var bytesIn: UInt64
    var bytesOut: UInt64
}

struct RaoClassifier {
    let app: RaoApp

    /// Model downloads only receive; more than this sent to a download host is not a download.
    static let downloadUploadLimit: UInt64 = 5 * 1_048_576

    /// Pure. `hostnames` are the names known for the remote address (forward-resolved profile
    /// hosts first, then reverse DNS); `settings` are the app's saved boolean settings.
    func classify(_ flow: FlowFacts, mode: ConsentMode, hostnames: [String], settings: [String: Bool]) -> FlowClassification {
        let effective: ConsentMode = mode == .unknown ? .onDevice : mode
        var result = classifyKnown(flow, mode: effective, hostnames: hostnames, settings: settings)
        if mode == .unknown, flow.scope == .external {
            result.modeWasUnknown = true
            if result.kind == .unexpected { result.note += " (mode unknown — held to on-device rules)" }
        }
        return result
    }

    private func classifyKnown(_ flow: FlowFacts, mode: ConsentMode, hostnames: [String], settings: [String: Bool]) -> FlowClassification {
        if flow.direction == .listening {
            let port = flow.localPort.map { ":\($0)" } ?? ""
            if flow.scope == .loopback || FlowScope.isLoopbackAddress(flow.localAddress) {
                let label = app.loopbackLabel(flow.localPort).map { "\($0) " } ?? ""
                return .init(kind: .local, note: "\(label)listening on this Mac only (\(port.isEmpty ? "no port" : port))")
            }
            if flow.proto.isUDP {
                if flow.bytesIn == 0 && flow.bytesOut == 0 {
                    return .init(kind: .local, note: "Idle UDP socket\(port.isEmpty ? "" : " on \(port)") — no traffic")
                }
                return .init(kind: .unexpected,
                             note: "UDP socket open to the network\(port.isEmpty ? "" : " on \(port)") moved \(formatBytes(flow.bytesIn)) in / \(formatBytes(flow.bytesOut)) out; its destinations aren't visible")
            }
            return .init(kind: .unexpected, note: "Listening on every network interface\(port.isEmpty ? "" : " on \(port)") — reachable from other devices")
        }

        if flow.scope == .loopback {
            if let label = app.loopbackLabel(flow.remotePort) ?? app.loopbackLabel(flow.localPort) {
                return .init(kind: .local, note: "\(label), on this Mac")
            }
            let port = flow.remotePort ?? flow.localPort
            return .init(kind: .local,
                         note: "Loopback port \(port.map(String.init) ?? "?") — stays on this Mac, but isn't one of \(app.name)'s known ports",
                         unknownLoopbackPort: true)
        }

        var wrongMode: (ExpectedHost, String)?
        var settingOff: (ExpectedHost, String, String)?
        for rule in app.expectedHosts where rule.processes?.contains(flow.process) ?? true {
            guard let host = rule.match(candidates: hostnames, remotePort: flow.remotePort) else { continue }
            if !rule.modes.contains(mode) {
                if wrongMode == nil { wrongMode = (rule, host) }
                continue
            }
            if let key = rule.requiresSetting, settings[key] == false {
                let label = app.consentStore?.settings.first { $0.key == key }?.label ?? key
                if settingOff == nil { settingOff = (rule, host, label) }
                continue
            }
            if rule.firstRunOnly, flow.bytesOut > Self.downloadUploadLimit {
                return .init(kind: .unexpected,
                             note: "Sent \(formatBytes(flow.bytesOut)) to \(host.isEmpty ? flow.remoteAddress : host) — a model download only receives",
                             matchedHost: host)
            }
            return .init(kind: .expected, note: rule.purpose, matchedHost: host.isEmpty ? nil : host,
                         broad: rule.broad, firstRun: rule.firstRunOnly)
        }
        let shown = hostnames.first ?? flow.remoteAddress
        if let (rule, host) = wrongMode {
            let allowed = rule.modes.map(\.displayName).sorted().joined(separator: " or ")
            return .init(kind: .unexpected,
                         note: "\(host.isEmpty ? shown : host): \(rule.purpose) — allowed only when \(allowed); \(app.name) is \(mode.displayName.lowercased())",
                         matchedHost: host.isEmpty ? nil : host)
        }
        if let (rule, host, label) = settingOff {
            return .init(kind: .unexpected,
                         note: "\(host.isEmpty ? shown : host): \(rule.purpose) — but \u{201C}\(label)\u{201D} is off in \(app.name)'s settings",
                         matchedHost: host.isEmpty ? nil : host)
        }
        let port = flow.remotePort.map { ":\($0)" } ?? ""
        return .init(kind: .unexpected, note: "\(shown)\(port) is not a host \(app.name) is known to contact")
    }
}
