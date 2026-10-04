import Foundation

/// Masks what in a command line could be a secret, so arguments can be shown and matched without
/// carrying credentials anywhere. Program names, subcommands, package names and plain paths
/// survive; flag values, assignments and tokens that look secret do not.
package enum ArgumentRedactor {

    package static let mask = "•••"

    /// Flags whose next argument (or `=value`) is a secret.
    private static let secretFlags: Set<String> = [
        "--token", "--api-key", "--apikey", "--key", "--secret", "--password", "--passwd",
        "--auth", "--authorization", "--bearer", "--access-token", "--refresh-token",
        "--client-secret", "--cookie", "-p", "-u", "--user",
    ]
    /// Name fragments that make an assignment (`NAME=value`) or header secret.
    private static let secretWords = [
        "token", "secret", "password", "passwd", "apikey", "api_key", "api-key", "auth",
        "credential", "cookie", "session", "private", "signature", "key",
    ]

    package static func redact(_ arguments: [String]) -> [String] {
        var out: [String] = []
        var maskNext = false
        for argument in arguments {
            if maskNext {
                out.append(mask)
                maskNext = false
                continue
            }
            let lower = argument.lowercased()
            // --flag value  /  --flag=value
            if let eq = argument.firstIndex(of: "="), argument.hasPrefix("-") {
                let flag = String(lower[..<eq])
                out.append(secretFlags.contains(flag) || isSecretName(flag) ? "\(argument[..<eq])=\(mask)" : redactValue(argument))
                continue
            }
            if secretFlags.contains(lower) {
                out.append(argument)
                maskNext = true
                continue
            }
            // A URL: strip credentials and secret query parameters, keep the rest. Handled
            // before the generic `name=value` rule so a `?api_key=…&page=2` keeps `page=2`.
            if argument.contains("://") {
                out.append(redactValue(argument))
                continue
            }
            // -H "Authorization: Bearer …"
            if let colon = argument.firstIndex(of: ":"), isSecretName(String(lower[..<colon])) {
                out.append("\(argument[..<colon]): \(mask)")
                continue
            }
            // NAME=value
            if let eq = argument.firstIndex(of: "="), !argument.hasPrefix("-"), isSecretName(String(lower[..<eq])) {
                out.append("\(argument[..<eq])=\(mask)")
                continue
            }
            out.append(redactValue(argument))
        }
        return out
    }

    private static func isSecretName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return secretWords.contains { trimmed.contains($0) }
    }

    /// Strip URL credentials and query secrets; mask long high-entropy tokens.
    private static func redactValue(_ value: String) -> String {
        if let url = URLComponents(string: value), url.scheme != nil, url.host != nil {
            var clean = url
            if clean.user != nil || clean.password != nil {
                clean.user = clean.user.map { _ in mask }
                clean.password = nil
            }
            if let items = clean.queryItems, !items.isEmpty {
                clean.queryItems = items.map { item in
                    isSecretName(item.name.lowercased()) ? URLQueryItem(name: item.name, value: mask) : item
                }
            }
            return clean.string ?? mask
        }
        return looksLikeToken(value) ? mask : value
    }

    /// A long run of mixed letters and digits with no path or package structure: an API key,
    /// a JWT, a hex secret.
    package static func looksLikeToken(_ value: String) -> Bool {
        guard value.count >= 24, !value.contains("/"), !value.contains(" ") else { return false }
        if value.split(separator: ".").count == 3, value.hasPrefix("eyJ") { return true }  // JWT
        let letters = value.filter(\.isLetter).count
        let digits = value.filter(\.isNumber).count
        let symbols = value.count - letters - digits
        guard letters > 0, digits > 0, symbols <= value.count / 6 else { return false }
        var classes = Set<Character.Kind>()
        for c in value { classes.insert(c.kind) }
        return classes.count >= 3 || (digits >= 6 && letters >= 6)
    }
}

private extension Character {
    enum Kind { case lower, upper, digit, other }
    var kind: Kind {
        if isLowercase { return .lower }
        if isUppercase { return .upper }
        if isNumber { return .digit }
        return .other
    }
}
