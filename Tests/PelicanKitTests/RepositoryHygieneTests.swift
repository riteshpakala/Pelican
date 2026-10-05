import Foundation
import Testing
@testable import PelicanKit

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

    private static let textExtensions: Set<String> = [
        "swift", "md", "sh", "plist", "xml", "entitlements", "json", "toml",
        "template", "xcscheme", "xcworkspacedata", "resolved",
    ]

    /// Everything a contributor commits: sources, tests, scripts, docs, the installer, the
    /// signing templates, and the Xcode state that is easy to forget.
    private static let everything = [
        "Sources", "Tests", "scripts", "docs", "pkg", "Support", ".swiftpm",
        "README.md", "Package.swift", "Package.resolved",
    ]

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
        for file in Self.files(under: Self.everything) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(home), "\(file.lastPathComponent) contains this machine's home directory")
        }
    }

    @Test func teamIdentifiersAppearOnlyInTheAIToolsCatalog() throws {
        // A quoted ten-character run of capitals and digits, with both: the shape of an Apple
        // team identifier.
        let pattern = try NSRegularExpression(pattern: "\"([A-Z0-9]{10})\"")
        var catalogTeams: Set<String> = []
        for file in Self.files(under: Self.everything) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let token = String(text[Range(match.range(at: 1), in: text)!])
                guard token.contains(where: \.isLetter), token.contains(where: \.isNumber) else { continue }
                // Two places may name a team, and only ever another vendor's: the AI tools
                // catalog, which records what macOS reports for their apps, and the fixtures
                // that test it. Anywhere else is a leak.
                let isCatalog = file.lastPathComponent == "AIToolCatalog.swift"
                let isFixture = file.pathComponents.contains("Tests")
                if isCatalog {
                    catalogTeams.insert(token)
                } else if !isFixture {
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
        for file in Self.files(under: Self.everything) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let name = String(text[Range(match.range(at: 2), in: text)!]).trimmingCharacters(in: .whitespaces)
                // Fixtures say "Example" and documentation writes <name>; a real certificate
                // names a person or a company.
                guard name != "Example", !name.hasPrefix("<") else { continue }
                Issue.record("\(file.lastPathComponent) names a signing identity: \(name)")
            }
        }
    }

    @Test func diagnosticsNeverPrintATeamIdentifier() {
        // The line systemextensionsctl prints, with a made-up identifier.
        let line = "\t*\tAB12CD34EF\tnyc.rao.pelican.tunnel (0.2.0/1)\tPelican Tunnel\t[activated enabled]"
        let masked = PrivateDetails.maskTeamIdentifiers(line)
        #expect(!masked.contains("AB12CD34EF"))
        #expect(masked.contains("(team)"))
        // The rest survives: the bundle id and the state are what the line is for.
        #expect(masked.contains("nyc.rao.pelican.tunnel"))
        #expect(masked.contains("[activated enabled]"))
        // Plain words and numbers are not mistaken for one.
        #expect(PrivateDetails.maskTeamIdentifiers("EXTENSIONS 1234567890") == "EXTENSIONS 1234567890")
    }

    @Test func homeFoldersAreWrittenAsTilde() {
        #expect(PrivateDetails.tilde("/Users/ada/projects/x", home: "/Users/ada") == "~/projects/x")
        #expect(PrivateDetails.tilde("/usr/bin/curl", home: "/Users/ada") == "/usr/bin/curl")
    }

    @Test func noEmailAddressIsCommitted() throws {
        // Placeholders are how documentation and fixtures talk about addresses; a real one is
        // somebody's, and this repository is public.
        let allowed = ["noreply@anthropic.com", "ada@example.org", "<apple-id>"]
        let pattern = try NSRegularExpression(
            pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
        for file in Self.files(under: Self.everything) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let address = String(text[Range(match.range, in: text)!])
                guard !allowed.contains(address),
                      !address.hasSuffix("example.com"), !address.hasSuffix("example.org")
                else { continue }
                Issue.record("\(file.lastPathComponent) contains the address \(address)")
            }
        }
    }
}
