import Foundation
import Testing
@testable import PelicanGuard
@testable import PelicanKit

// MARK: - Fixtures

private let secrets = [
    "ada@example.org",
    "studio-mac",
    "sk-abcdefghij0123456789",
    "4111 1111 1111 1111",
]

@MainActor
private func makeGuard() -> (LeakGuard, DayFileStore<GuardDay>) {
    let store = DayFileStore<GuardDay>(
        folder: "guard",
        root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pelican-guard-\(UUID().uuidString)"))
    let guard_ = LeakGuard(
        detectors: [
            MachineIdentityDetector(values: [("this Mac's name", .device, "studio-mac")]),
            PatternDetector(),
            FieldNameDetector(),
        ],
        store: store)
    guard_.setObserving(true)
    return (guard_, store)
}

/// A synthetic readable exchange of the shape the inspection engine will produce: a model
/// request whose body carries personal details and a key.
private func exchange() -> InspectedExchange {
    InspectedExchange(
        id: "x1", startedAt: Date(), source: .manualProxy, state: .complete,
        originName: "claude", pid: 16186, toolID: "claude",
        method: "POST", authority: "api.anthropic.com", path: "/v1/messages",
        requestHeaders: [
            .init(name: "authorization", value: "•••", masked: true),
            .init(name: "x-client-host", value: "studio-mac"),
        ],
        requestBody: .init(
            text: #"{"messages":[{"role":"user","content":"email ada@example.org, card 4111 1111 1111 1111, key sk-abcdefghij0123456789"}],"device_id":"x"}"#,
            wireByteCount: 180),
        responseStatus: 200)
}

// MARK: - Tests

@Suite @MainActor struct LeakGuardTests {

    @Test func aReadableExchangeProducesSeenFindingsSaysWhereAndMasksTheValue() throws {
        let (guard_, _) = makeGuard()
        let found = guard_.scan(exchange())
        let subjects = Set(found.map(\.subject))
        #expect(subjects.contains("an email address"))
        #expect(subjects.contains("a payment card number"))
        #expect(subjects.contains("an API key"))
        #expect(subjects.contains("this Mac's name"))
        // Known only by its field name, and the subject says so.
        #expect(subjects.contains("a device identifier, named in the request"))
        #expect(found.allSatisfy { $0.evidence.isSeen })
        let email = try #require(found.first { $0.subject == "an email address" })
        #expect(email.evidence == .seen(where: "request body"))
        #expect(email.maskedSample == "a•••@e•••.org")
    }

    @Test func aMaskedHeaderIsNeverScanned() {
        let (guard_, _) = makeGuard()
        let found = guard_.scan(exchange())
        #expect(!found.contains { finding in
            if case .seen(let location) = finding.evidence { return location.contains("authorization") }
            return false
        })
    }

    @Test func nothingRawReachesTheSavedRecord() throws {
        let (guard_, store) = makeGuard()
        defer { try? FileManager.default.removeItem(at: store.root) }
        guard_.scan(exchange())
        #expect(!guard_.day.findings.isEmpty)
        guard_.flushNow()
        let saved = try String(contentsOf: store.url(day: guard_.day.day), encoding: .utf8)
        for secret in secrets {
            #expect(!saved.contains(secret), "the saved record contains \(secret)")
        }
        // And the in-memory record never held them either.
        let inMemory = String(describing: guard_.day)
        for secret in secrets {
            #expect(!inMemory.contains(secret), "the in-memory record contains \(secret)")
        }
    }

    @Test func aReadingReplacesAGuessAboutTheSameThing() throws {
        let (guard_, _) = makeGuard()
        // A prediction first…
        let likely = ExposureFinding(
            id: "claude|api.anthropic.com|identity|an email address|seen",
            subject: "an email address", category: .identity,
            evidence: .likely(.documented("guess")), detail: "guess",
            originName: "claude", toolID: "claude", endpoint: "api.anthropic.com",
            firstSeen: Date(), lastSeen: Date())
        guard_.inject(likely)
        // …then the same thing actually read.
        guard_.scan(exchange())
        let finding = try #require(guard_.day.findings.first { $0.id == likely.id })
        #expect(finding.evidence.isSeen)
        #expect(finding.count == 2)
    }

    @Test func seenAndLikelyAreCountedSeparately() {
        let (guard_, _) = makeGuard()
        guard_.scan(exchange())
        guard_.predict(originName: "claude", toolID: "claude",
                       endpoint: "http-intake.logs.us5.datadoghq.com",
                       candidates: ["http-intake.logs.us5.datadoghq.com"],
                       bytesOut: 4_000, bytesIn: 100)
        #expect(guard_.day.seen.count > 0)
        #expect(guard_.day.likely.count > 0)
        #expect(guard_.summaryLine == "Leak Guard: \(guard_.day.seen.count) seen, \(guard_.day.likely.count) likely")
    }

    @Test func pausedMeansNothingIsRecorded() {
        let (guard_, _) = makeGuard()
        guard_.setObserving(false)
        #expect(guard_.scan(exchange()).isEmpty)
        #expect(guard_.day.findings.isEmpty)
    }

    @Test func readableTrafficTeachesTheEndpointProfileCategoriesOnly() throws {
        let (guard_, _) = makeGuard()
        for _ in 0..<5 { guard_.scan(exchange()) }
        let profile = try #require(guard_.day.profiles.first { $0.endpoint == "api.anthropic.com" })
        #expect(profile.samples == 5)
        #expect(profile.isConfident)
        #expect(profile.categories.contains(.identity))
        #expect(!String(describing: profile).contains("ada@example.org"))
    }
}

@Suite struct ExposurePredictorTests {

    private let predictor = ExposurePredictor()

    @Test func aCollectorIsNamedAndEveryFindingIsLikely() throws {
        let found = predictor.predict(
            originName: "claude", toolID: "claude", endpoint: "http-intake.logs.us5.datadoghq.com",
            candidates: ["http-intake.logs.us5.datadoghq.com"], bytesOut: 4_000, bytesIn: 100, at: Date())
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { !$0.evidence.isSeen })
        let first = try #require(found.first)
        guard case .likely(.collector(let what)) = first.evidence else {
            Issue.record("expected a collector basis, got \(first.evidence)"); return
        }
        #expect(what.contains("Datadog"))
    }

    @Test func aVendorClaimIsCarriedAsDocumentedNotAsFact() throws {
        let found = predictor.predict(
            originName: "claude", toolID: "claude", endpoint: "http-intake.logs.us5.datadoghq.com",
            candidates: [], claims: ["Metrics \"never include your code, prompts, or file paths\"."],
            bytesOut: 10, bytesIn: 10, at: Date())
        let claim = try #require(found.first { if case .likely(.documented) = $0.evidence { return true }; return false })
        #expect(claim.detail.contains("cannot check this"))
    }

    @Test func aLopsidedUploadIsFlaggedByVolumeAndSaysSo() throws {
        let found = predictor.predict(
            originName: "repo-sync", toolID: nil, endpoint: "repo42.cursor.sh", candidates: [],
            bytesOut: 50 * 1_048_576, bytesIn: 1_000_000, at: Date())
        let volume = try #require(found.first { if case .likely(.volume) = $0.evidence { return true }; return false })
        #expect(volume.category == .content)
        #expect(volume.detail.contains("cannot see what it was"))
    }

    @Test func anOrdinaryExchangeToAnUnknownHostPredictsNothing() {
        let found = predictor.predict(
            originName: "curl", toolID: nil, endpoint: "example.com", candidates: ["example.com"],
            bytesOut: 2_000, bytesIn: 40_000, at: Date())
        #expect(found.isEmpty)
    }

    @Test func aProfileNeedsEnoughSamplesBeforeItPredicts() {
        var profile = EndpointProfile(id: "a|b", originName: "a", endpoint: "b",
                                      categories: [.identity], samples: 4, since: Date(), lastSeen: Date())
        #expect(predictor.predict(originName: "a", toolID: nil, endpoint: "b", candidates: [],
                                  profile: profile, bytesOut: 1, bytesIn: 1, at: Date()).isEmpty)
        profile.samples = 5
        let found = predictor.predict(originName: "a", toolID: nil, endpoint: "b", candidates: [],
                                      profile: profile, bytesOut: 1, bytesIn: 1, at: Date())
        #expect(found.count == 1)
        if case .likely(.learned(let samples, _)) = found.first?.evidence {
            #expect(samples == 5)
        } else {
            Issue.record("expected a learned basis")
        }
    }
}
