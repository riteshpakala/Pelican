import Foundation

/// Removes details that identify a developer account or a person from text Pelican prints,
/// so a diagnostic can be pasted into an issue without exposing them.
package enum PrivateDetails {

    /// Replace anything shaped like an Apple Team ID — ten capitals and digits, with both —
    /// by "(team)". `systemextensionsctl` and `codesign` print one on every line they describe.
    package static func maskTeamIdentifiers(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "\\b[A-Z0-9]{10}\\b") else { return text }
        var out = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let token = out[range]
            // A team identifier mixes capitals and digits; a plain word or number does not.
            if token.contains(where: \.isLetter) && token.contains(where: \.isNumber) {
                out.replaceSubrange(range, with: "(team)")
            }
        }
        return out
    }

    /// Write the home folder as `~`.
    package static func tilde(_ path: String,
                              home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
