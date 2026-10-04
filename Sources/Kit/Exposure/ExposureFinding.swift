import Foundation

/// The kind of personal information a finding is about.
package enum DataCategory: String, Sendable, Codable, CaseIterable {
    case identity       // a name, an email address, an account
    case device         // this Mac: its name, serial, hardware id
    case location
    case credentials    // keys, tokens, passwords
    case financial
    case governmentID
    case contacts
    case content        // what you wrote or read: files, prompts, pages
    case usage          // how you use something
    case diagnostics    // crashes and errors

    package var label: String {
        switch self {
        case .identity: return "who you are"
        case .device: return "this Mac"
        case .location: return "where you are"
        case .credentials: return "credentials"
        case .financial: return "financial"
        case .governmentID: return "government ID"
        case .contacts: return "contacts"
        case .content: return "what you wrote"
        case .usage: return "how you use it"
        case .diagnostics: return "diagnostics"
        }
    }

    /// Worth saying loudly: a secret, or something that identifies a person.
    package var isSensitive: Bool {
        switch self {
        case .credentials, .financial, .governmentID, .identity, .location, .contacts: return true
        case .device, .content, .usage, .diagnostics: return false
        }
    }
}

/// How Pelican knows. The whole point of the guard is that these two never blur together:
/// one is a reading, the other is an inference, and the user is always told which.
package enum ExposureEvidence: Sendable, Hashable, Codable {
    /// Found in content Pelican could actually read. `where` says where in it.
    case seen(where: String)
    /// The traffic was encrypted. The basis says what the guess rests on.
    case likely(ExposureBasis)

    package var isSeen: Bool { if case .seen = self { return true }; return false }

    /// The word a row leads with.
    package var word: String { isSeen ? "Seen" : "Likely" }
}

/// Why Pelican thinks something is probably in traffic it cannot read.
package enum ExposureBasis: Sendable, Hashable, Codable {
    /// The vendor's own documentation for this endpoint says so.
    case documented(String)
    /// Earlier readable traffic to the same endpoint on this Mac carried it.
    case learned(samples: Int, since: Date)
    /// The destination is a known telemetry, analytics or crash collector.
    case collector(String)
    /// Far more was sent than received — too much to be a prompt alone.
    case volume(String)

    package var sentence: String {
        switch self {
        case .documented(let source): return source
        case .learned(let samples, let since):
            let day = DateFormatter.localizedString(from: since, dateStyle: .medium, timeStyle: .none)
            return "\(samples) earlier readable request\(samples == 1 ? "" : "s") to this endpoint since \(day) carried it"
        case .collector(let what): return what
        case .volume(let what): return what
        }
    }
}

/// One thing that left, or probably left, this Mac.
///
/// A finding never holds the value it is about. It holds a masked sample, so a person can
/// recognise what was found without the record becoming a copy of it.
package struct ExposureFinding: Sendable, Hashable, Codable, Identifiable {
    package var id: String
    package var subject: String
    package var category: DataCategory
    package var evidence: ExposureEvidence
    /// One sentence a person can act on.
    package var detail: String
    /// Enough of the value to recognise it, never enough to use it.
    package var maskedSample: String?
    /// The app or tool it left from, and the process.
    package var originName: String
    package var toolID: String?
    /// Where it went.
    package var endpoint: String
    package var firstSeen: Date
    package var lastSeen: Date
    package var count: Int

    package init(id: String, subject: String, category: DataCategory, evidence: ExposureEvidence,
                 detail: String, maskedSample: String? = nil, originName: String,
                 toolID: String? = nil, endpoint: String, firstSeen: Date, lastSeen: Date,
                 count: Int = 1) {
        self.id = id
        self.subject = subject
        self.category = category
        self.evidence = evidence
        self.detail = detail
        self.maskedSample = maskedSample
        self.originName = originName
        self.toolID = toolID
        self.endpoint = endpoint
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.count = count
    }

    /// "Seen: your email address went to api.example.com"
    package var headline: String {
        "\(evidence.word): \(subject) \(evidence.isSeen ? "went to" : "probably goes to") \(endpoint)"
    }
}

/// Masks a value so it can be recognised but not used.
package enum ExposureMask {

    /// Keep a little shape, hide the rest: "ritesh@rao.nyc" → "r•••@r•••.nyc".
    package static func sample(_ value: String, category: DataCategory) -> String {
        switch category {
        case .credentials:
            // Never show any of a secret beyond its shape.
            return "\(value.count) characters"
        case .financial, .governmentID:
            let digits = value.filter(\.isNumber)
            return digits.count > 4 ? "•••• \(digits.suffix(4))" : "••••"
        case .identity where value.contains("@"):
            let parts = value.split(separator: "@", maxSplits: 1)
            guard parts.count == 2 else { return redact(value) }
            let domain = parts[1].split(separator: ".")
            let tail = domain.count > 1 ? "." + domain.dropFirst().joined(separator: ".") : ""
            return "\(parts[0].prefix(1))•••@\(domain.first?.prefix(1) ?? "")•••\(tail)"
        default:
            return redact(value)
        }
    }

    /// First character, then dots: enough to recognise, not to read.
    package static func redact(_ value: String) -> String {
        guard value.count > 2 else { return "•••" }
        return "\(value.prefix(1))••• (\(value.count) characters)"
    }
}
