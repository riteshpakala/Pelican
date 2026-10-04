import Foundation
import Testing

/// Pelican is read by the people it protects, so the repository must not carry anyone's
/// private details: no home directory, and no Apple team identifier except other vendors'
/// published ones in the AI tools catalog.
@Suite struct RepositoryHygieneTests {

    private static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return url
    }()

    private static let textExtensions: Set<String> = ["swift", "md", "sh", "plist", "xml", "entitlements", "json", "toml"]

    /// Every text file a contributor would commit (build products and dependency checkouts excluded).
    private static func files(under directories: [String]) -> [URL] {
        var out: [URL] = []
        for directory in directories {
            let base = root.appendingPathComponent(directory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue { out.append(base); continue }
            let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                if textExtensions.contains(url.pathExtension) { out.append(url) }
            }
        }
        return out
    }

    @Test func noHomeDirectoryIsCommitted() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        for file in Self.files(under: ["Sources", "Tests", "scripts", "docs", "pkg", "Support", "README.md", "Package.swift"]) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(home), "\(file.lastPathComponent) contains this machine's home directory")
        }
    }

    @Test func teamIdentifiersAppearOnlyInTheAIToolsCatalog() throws {
        // A quoted ten-character run of capitals and digits, with both: the shape of an Apple
        // team identifier.
        let pattern = try NSRegularExpression(pattern: "\"([A-Z0-9]{10})\"")
        var catalogTeams: Set<String> = []
        for file in Self.files(under: ["Sources"]) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let token = String(text[Range(match.range(at: 1), in: text)!])
                guard token.contains(where: \.isLetter), token.contains(where: \.isNumber) else { continue }
                if file.lastPathComponent == "AIToolCatalog.swift" {
                    catalogTeams.insert(token)
                } else {
                    Issue.record("\(file.lastPathComponent) contains the team-identifier-shaped literal \(token); only the AI tools catalog may name a team, and only another vendor's")
                }
            }
        }
        // The catalog does name the vendors it has fingerprinted.
        #expect(!catalogTeams.isEmpty)
    }

    @Test func noSigningIdentityNamesAPerson() throws {
        // "Developer ID Application: <name> (<team>)" must never appear with a real name in the
        // sources or scripts. Tests use "Example"; the catalog quotes no certificate subjects.
        let pattern = try NSRegularExpression(pattern: "Developer ID (Application|Installer): ([^\"(…]+)\\(")
        for file in Self.files(under: ["Sources", "scripts", "docs", "README.md"]) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let name = String(text[Range(match.range(at: 2), in: text)!]).trimmingCharacters(in: .whitespaces)
                Issue.record("\(file.lastPathComponent) names a signing identity: \(name)")
            }
        }
    }
}
