import CryptoKit
import Foundation
import PelicanKit

/// Something a detector found in a piece of text.
package struct Detection: Sendable, Hashable {
    package var subject: String
    package var category: DataCategory
    /// The matched text. Masked before it ever leaves the guard; never stored.
    package var value: String
    /// How the value appeared, when it was not literal ("base64-encoded", "SHA-256 of").
    package var form: String?

    package init(subject: String, category: DataCategory, value: String, form: String? = nil) {
        self.subject = subject
        self.category = category
        self.value = value
        self.form = form
    }

    package var describedSubject: String {
        guard let form else { return subject }
        return "\(subject), \(form)"
    }
}

package protocol ExposureDetector: Sendable {
    var name: String { get }
    func scan(_ text: String) -> [Detection]
}

// MARK: - This Mac

/// The identifiers that belong to this machine and the person using it, in the forms they
/// travel in: literal, URL-encoded, base64, and hashed.
///
/// Read once at startup and held in memory only. None of it is ever written to the record —
/// the whole point is to notice when it leaves, not to keep another copy of it.
package struct MachineIdentityDetector: ExposureDetector {
    package let name = "this Mac"

    private struct Term {
        let subject: String
        let category: DataCategory
        /// Literal and derived spellings, lowercased for matching.
        let spellings: [(form: String?, text: String)]
    }
    private let terms: [Term]
    /// Shortest literal worth matching: below this, false positives swamp it.
    package static let minimumLength = 5

    package init(values: [(subject: String, category: DataCategory, value: String)]) {
        terms = values.compactMap { entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= Self.minimumLength else { return nil }
            var spellings: [(String?, String)] = [(nil, value.lowercased())]
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               encoded.lowercased() != value.lowercased() {
                spellings.append(("URL-encoded", encoded.lowercased()))
            }
            spellings.append(("base64-encoded", Data(value.utf8).base64EncodedString().lowercased()))
            let digest = SHA256.hash(data: Data(value.utf8))
            spellings.append(("hashed with SHA-256", digest.map { String(format: "%02x", $0) }.joined()))
            return Term(subject: entry.subject, category: entry.category, spellings: spellings)
        }
    }

    /// What this Mac can tell about itself.
    package static func current(host: String = ProcessInfo.processInfo.hostName,
                                userName: String = NSUserName(),
                                fullName: String = NSFullUserName(),
                                home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                serial: String? = IOPlatform.serialNumber,
                                hardwareUUID: String? = IOPlatform.hardwareUUID) -> MachineIdentityDetector {
        var values: [(String, DataCategory, String)] = [
            ("this Mac's name", .device, host),
            ("your macOS account name", .identity, userName),
            ("your full name", .identity, fullName),
            ("your home folder path", .identity, home),
        ]
        if let serial { values.append(("this Mac's serial number", .device, serial)) }
        if let hardwareUUID { values.append(("this Mac's hardware id", .device, hardwareUUID)) }
        return MachineIdentityDetector(values: values)
    }

    package func scan(_ text: String) -> [Detection] {
        let haystack = text.lowercased()
        var out: [Detection] = []
        for term in terms {
            for spelling in term.spellings where haystack.contains(spelling.text) {
                out.append(Detection(subject: term.subject, category: term.category,
                                     value: spelling.text, form: spelling.form))
                break   // one finding per term, naming the first form found
            }
        }
        return out
    }
}

/// Reads the two machine identifiers that need IOKit.
package enum IOPlatform {
    package static let serialNumber: String? = value(forKey: "IOPlatformSerialNumber")
    package static let hardwareUUID: String? = value(forKey: "IOPlatformUUID")

    private static func value(forKey key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? String
    }
}

// MARK: - Patterns

/// Email addresses, phone numbers and postal addresses, via the system's own data detectors,
/// plus the patterns those do not cover.
package struct PatternDetector: ExposureDetector {
    package let name = "patterns"

    private static let dataDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue)
    private static let email = try! NSRegularExpression(
        pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: .caseInsensitive)
    private static let card = try! NSRegularExpression(pattern: "\\b(?:\\d[ -]?){13,19}\\b")
    private static let ssn = try! NSRegularExpression(pattern: "\\b(?!000|666|9\\d\\d)\\d{3}-(?!00)\\d{2}-(?!0000)\\d{4}\\b")
    private static let jwt = try! NSRegularExpression(pattern: "\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b")
    private static let pem = try! NSRegularExpression(pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----")
    private static let apiKey = try! NSRegularExpression(
        pattern: "\\b(sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})\\b")
    private static let homePath = try! NSRegularExpression(pattern: "/Users/[A-Za-z0-9._-]{2,}")

    package init() {}

    package func scan(_ text: String) -> [Detection] {
        var out: [Detection] = []
        let range = NSRange(text.startIndex..., in: text)

        func matches(_ expression: NSRegularExpression, _ subject: String, _ category: DataCategory,
                     validate: (String) -> Bool = { _ in true }) {
            for match in expression.matches(in: text, range: range) {
                guard let found = Range(match.range, in: text) else { continue }
                let value = String(text[found])
                guard validate(value) else { continue }
                out.append(Detection(subject: subject, category: category, value: value))
                return   // one per kind per text; the count is what matters, not every instance
            }
        }

        matches(Self.email, "an email address", .identity)
        matches(Self.jwt, "a signed token", .credentials)
        matches(Self.pem, "a private key", .credentials)
        matches(Self.apiKey, "an API key", .credentials)
        matches(Self.ssn, "a social security number", .governmentID)
        matches(Self.homePath, "a path under /Users", .identity)
        matches(Self.card, "a payment card number", .financial) { Self.passesLuhn($0) }

        if let detector = Self.dataDetector {
            for match in detector.matches(in: text, range: range) {
                guard let found = Range(match.range, in: text) else { continue }
                let value = String(text[found])
                switch match.resultType {
                case .phoneNumber:
                    // Phone detection fires on many bare number runs; require punctuation.
                    if value.contains(where: { "()-+ ".contains($0) }) {
                        out.append(Detection(subject: "a phone number", category: .identity, value: value))
                    }
                case .address:
                    out.append(Detection(subject: "a postal address", category: .location, value: value))
                default: break
                }
            }
        }
        return out
    }

    /// A card number's checksum. Without this, any long digit run looks like a card.
    package static func passesLuhn(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

/// Field names that say what a value is, for structured bodies where the value itself is
/// unremarkable: `"device_id": "…"`, `"lat": 51.5`.
package struct FieldNameDetector: ExposureDetector {
    package let name = "field names"

    private static let fields: [(pattern: String, subject: String, category: DataCategory)] = [
        ("device_?id|machine_?id|install(ation)?_?id|client_?id", "a device identifier", .device),
        ("\\blat(itude)?\\b|\\blon(gitude)?\\b|\\bgeo\\b", "your location", .location),
        ("email|e_?mail", "an email address", .identity),
        ("phone|mobile_?number", "a phone number", .identity),
        ("user_?name|full_?name|given_?name|family_?name", "your name", .identity),
        ("session_?id|session_?token", "a session identifier", .credentials),
        ("ip_?address|client_?ip", "your IP address", .location),
    ]
    private static let expressions: [(NSRegularExpression, String, DataCategory)] = fields.compactMap {
        guard let expression = try? NSRegularExpression(
            pattern: "\"(\($0.pattern))\"\\s*:", options: .caseInsensitive) else { return nil }
        return (expression, $0.subject, $0.category)
    }

    package init() {}

    package func scan(_ text: String) -> [Detection] {
        let range = NSRange(text.startIndex..., in: text)
        var out: [Detection] = []
        for (expression, subject, category) in Self.expressions {
            guard let match = expression.firstMatch(in: text, range: range),
                  let found = Range(match.range, in: text) else { continue }
            out.append(Detection(subject: subject, category: category,
                                 value: String(text[found]), form: "named in the request"))
        }
        return out
    }
}
