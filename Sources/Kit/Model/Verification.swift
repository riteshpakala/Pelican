import Foundation

/// Whether Pelican has actually seen a fact on a Mac, or only read it in someone's
/// documentation. Shown beside every claim, and unverified facts never attribute anything.
///
/// Used by the AI tools catalog (observed by `--ai-probe`) and by the radio log patterns
/// (observed by `--radio-probe`).
package enum Verification: Sendable, Hashable, Codable {
    /// Observed by a probe on a real machine, on this date, at this version.
    case observed(on: String, version: String?)
    /// Published by the vendor. The string says where.
    case documented(String)
    /// Neither. Carried so an entry can be written before it is confirmed.
    case unverified

    package var isObserved: Bool { if case .observed = self { return true }; return false }

    package var note: String {
        switch self {
        case .observed(let day, let version):
            return "observed \(day)\(version.map { " at version \($0)" } ?? "")"
        case .documented(let source): return "documented — \(source)"
        case .unverified: return "not confirmed yet"
        }
    }
}
