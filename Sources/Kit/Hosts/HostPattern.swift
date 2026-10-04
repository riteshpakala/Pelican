import Foundation

/// How a rule names a host. Deliberately small: exact names and domain suffixes, matched
/// case-insensitively. No regex and no address ranges — a rule should be readable by the person
/// it protects.
package enum HostPattern: Sendable, Hashable, Codable {
    case exact(String)
    /// The domain itself and anything under it: `suffix("cursor.sh")` matches `api2.cursor.sh`.
    case suffix(String)

    /// How the rule reads on screen.
    package var display: String {
        switch self {
        case .exact(let host): return host
        case .suffix(let domain): return "*." + domain
        }
    }

    package func matches(_ candidate: String) -> Bool {
        let host = candidate.lowercased()
        switch self {
        case .exact(let name):
            return host == name.lowercased()
        case .suffix(let domain):
            let lower = domain.lowercased()
            return host == lower || host.hasSuffix("." + lower)
        }
    }

    /// The first of `candidates` this rule matches.
    package func firstMatch(in candidates: [String]) -> String? {
        candidates.first(where: matches)
    }
}
