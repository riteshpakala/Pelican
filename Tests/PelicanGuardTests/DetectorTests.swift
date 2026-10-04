import CryptoKit
import Foundation
import Testing
@testable import PelicanGuard
@testable import PelicanKit

@Suite struct PatternDetectorTests {

    private let detector = PatternDetector()
    private func subjects(_ text: String) -> [String] { detector.scan(text).map(\.subject) }

    @Test func findsAnEmailAddressAndAPathUnderUsers() {
        let found = subjects("contact me at ada@example.org about /Users/ada/notes.txt")
        #expect(found.contains("an email address"))
        #expect(found.contains("a path under /Users"))
    }

    @Test func cardNumbersNeedToPassTheirChecksum() {
        // A published test number, and the same digits with one changed.
        #expect(PatternDetector.passesLuhn("4111 1111 1111 1111"))
        #expect(!PatternDetector.passesLuhn("4111 1111 1111 1112"))
        #expect(subjects("card 4111 1111 1111 1111").contains("a payment card number"))
        #expect(!subjects("order 4111 1111 1111 1112").contains("a payment card number"))
        // Long digit runs that are not cards stay quiet.
        #expect(!subjects("build 20261004120000123456").contains("a payment card number"))
    }

    @Test func socialSecurityNumbersExcludeTheImpossibleRanges() {
        #expect(subjects("ssn 123-45-6789").contains("a social security number"))
        for invalid in ["000-45-6789", "666-45-6789", "900-45-6789", "123-00-6789", "123-45-0000"] {
            #expect(!subjects("ssn \(invalid)").contains("a social security number"), "\(invalid) matched")
        }
    }

    @Test func findsCredentialShapes() {
        #expect(subjects("token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJldmFsdWU")
            .contains("a signed token"))
        #expect(subjects("-----BEGIN RSA PRIVATE KEY-----").contains("a private key"))
        #expect(subjects("key sk-abcdefghij0123456789").contains("an API key"))
        #expect(subjects("aws AKIAIOSFODNN7EXAMPLE").contains("an API key"))
    }

    @Test func ordinaryProseFindsNothing() {
        #expect(detector.scan("Refactor the capture layer and run the tests again.").isEmpty)
        #expect(detector.scan("").isEmpty)
    }
}

@Suite struct MachineIdentityDetectorTests {

    private let detector = MachineIdentityDetector(values: [
        ("this Mac's name", .device, "studio-mac"),
        ("your macOS account name", .identity, "ada"),          // too short: ignored
        ("your full name", .identity, "Ada Lovelace"),
        ("this Mac's serial number", .device, "C02XK1ABCDEF"),
    ])

    @Test func findsItsTermsLiterally() {
        let found = detector.scan("host=studio-mac serial=C02XK1ABCDEF")
        #expect(found.map(\.subject).sorted() == ["this Mac's name", "this Mac's serial number"])
    }

    @Test func findsTheBase64EncodedForm() throws {
        let encoded = Data("Ada Lovelace".utf8).base64EncodedString()
        let found = try #require(detector.scan("user=\(encoded)").first)
        #expect(found.subject == "your full name")
        #expect(found.form == "base64-encoded")
        #expect(found.describedSubject == "your full name, base64-encoded")
    }

    @Test func findsTheHashedForm() throws {
        let digest = SHA256.hash(data: Data("Ada Lovelace".utf8)).map { String(format: "%02x", $0) }.joined()
        let found = try #require(detector.scan("id=\(digest)").first)
        #expect(found.form == "hashed with SHA-256")
        // A different hash of the same length is not a match.
        #expect(detector.scan("id=" + String(repeating: "ab", count: 32)).isEmpty)
    }

    @Test func shortTermsAreIgnoredSoCommonWordsDoNotMatch() {
        // "ada" is below the minimum length; otherwise every "ada" in any text would match.
        #expect(detector.scan("the adapter was reloaded").isEmpty)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(!detector.scan("HOST=STUDIO-MAC").isEmpty)
    }
}

@Suite struct FieldNameDetectorTests {

    @Test func namesInStructuredBodiesAreFound() {
        let found = FieldNameDetector().scan(#"{"device_id":"x","lat":51.5,"note":"hello"}"#)
        let subjects = found.map(\.subject)
        #expect(subjects.contains("a device identifier"))
        #expect(subjects.contains("your location"))
        #expect(found.allSatisfy { $0.form == "named in the request" })
    }

    @Test func aWordInProseIsNotAField() {
        #expect(FieldNameDetector().scan("the latitude of the problem is unclear").isEmpty)
    }
}

@Suite struct ExposureMaskTests {

    @Test func secretsShowOnlyTheirShape() {
        let masked = ExposureMask.sample("sk-abcdefghij0123456789", category: .credentials)
        #expect(!masked.contains("abcdefghij"))
        #expect(masked == "23 characters")
    }

    @Test func cardsAndIDsShowTheLastFour() {
        #expect(ExposureMask.sample("4111 1111 1111 1111", category: .financial) == "•••• 1111")
        #expect(ExposureMask.sample("123-45-6789", category: .governmentID) == "•••• 6789")
    }

    @Test func emailsKeepJustEnoughToRecognise() {
        let masked = ExposureMask.sample("ada@example.org", category: .identity)
        #expect(masked == "a•••@e•••.org")
        #expect(!masked.contains("ada@"))
    }

    @Test func anythingElseKeepsOnlyItsFirstCharacter() {
        let masked = ExposureMask.sample("studio-mac", category: .device)
        #expect(masked.hasPrefix("s•••"))
        #expect(!masked.contains("tudio"))
    }
}
