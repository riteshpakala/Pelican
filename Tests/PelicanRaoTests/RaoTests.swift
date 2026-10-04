import Foundation
import Testing
@testable import PelicanKit
@testable import PelicanRao

// MARK: - Fixtures

private func signature(_ identifier: String?, team: String? = "TEAMAAAAAA", leaf: String? = "Developer ID Application: Example (TEAMAAAAAA)",
                       valid: Bool = true, adHoc: Bool = false, runtime: Bool = true, notarized: Bool? = true) -> CodeSignature {
    CodeSignature(identifier: identifier, teamIdentifier: team, leafSubject: leaf,
                  leafKind: CodeSignature.LeafKind.classify(leaf), isValid: valid,
                  validityError: valid ? nil : "code has been modified", isAdHoc: adHoc, hardenedRuntime: runtime,
                  linkerSigned: false, cdHash: "abc", designatedRequirement: nil, notarized: notarized)
}

private func identity(pid: Int32, name: String, path: String, bundle: String? = nil, bundleId: String? = nil,
                      parent: Int32? = 1, signature: CodeSignature?) -> ProcessIdentity {
    ProcessIdentity(pid: pid, startTime: UInt64(pid) * 10, parentPid: parent, name: name, executablePath: path,
                    bundlePath: bundle, bundleIdentifier: bundleId, bundleVersion: "1.0.0", bundleBuild: "1",
                    launchedAt: Date(timeIntervalSince1970: 1_000), signature: signature)
}

private let released = identity(pid: 100, name: "Ambient", path: "/Applications/Ambient.app/Contents/MacOS/Ambient",
                                 bundle: "/Applications/Ambient.app", bundleId: "nyc.rao.ambient",
                                 signature: signature("nyc.rao.ambient"))

private func facts(_ process: String, remote: String = "1.2.3.4", port: UInt16? = 443, scope: FlowScope = .external,
                   direction: FlowDirection = .outbound, out: UInt64 = 100, local: String = "10.0.0.5",
                   localPort: UInt16? = 50000, proto: FlowProto = .tcp4) -> FlowFacts {
    FlowFacts(process: process, proto: proto, direction: direction, scope: scope, localAddress: local,
              localPort: localPort, remoteAddress: remote, remotePort: port, bytesIn: 1_000, bytesOut: out)
}

// MARK: - Attribution

@Suite struct RaoAttributionTests {
    let app = RaoApp.ambient

    @Test func signatureWinsOverName() {
        let helper = identity(pid: 2, name: "anything", path: "/tmp/x", signature: signature("nyc.rao.ambient.sewn-server"))
        let result = RaoAttributor.attribute(name: "anything", identity: helper, parentPid: 1, appPids: [],
                                             touchesKnownPorts: false, app: app)
        #expect(result?.role == .helper("sewn-server") && result?.confidence == .signature)
        let appResult = RaoAttributor.attribute(name: "Ambient", identity: released, parentPid: 1, appPids: [],
                                                touchesKnownPorts: false, app: app)
        #expect(appResult?.role == .app && appResult?.confidence == .signature)
    }

    @Test func sharedSewnFromAnotherRaoAppIsRecognised() {
        let helper = identity(pid: 3, name: "sewn-server", path: "/x", signature: signature("nyc.rao.craft.sewn-server"))
        let result = RaoAttributor.attribute(name: "sewn-server", identity: helper, parentPid: 1, appPids: [],
                                             touchesKnownPorts: false, app: app)
        #expect(result?.confidence == .signature)
    }

    @Test func devHelperNeedsParentOrPorts() {
        let dev = identity(pid: 4, name: "thread", path: "/src/Thread/.build/release/thread",
                           signature: signature("thread", team: nil, leaf: nil, adHoc: true, runtime: false, notarized: false))
        #expect(RaoAttributor.attribute(name: "thread", identity: dev, parentPid: 1, appPids: [], touchesKnownPorts: false, app: app) == nil)
        #expect(RaoAttributor.attribute(name: "thread", identity: dev, parentPid: 1, appPids: [], touchesKnownPorts: true, app: app)?.confidence == .portAffinity)
        #expect(RaoAttributor.attribute(name: "thread", identity: dev, parentPid: 100, appPids: [100], touchesKnownPorts: false, app: app)?.confidence == .childOfApp)
    }

    @Test func installedPathsAreRecognised() {
        let noSig = identity(pid: 5, name: "sewn-server", path: FileManager.default.homeDirectoryForCurrentUser.path + "/.rao/sewn/bin/sewn-server", signature: nil)
        #expect(RaoAttributor.attribute(name: "sewn-server", identity: noSig, parentPid: 1, appPids: [], touchesKnownPorts: false, app: app)?.confidence == .path)
    }

    @Test func aProcessMerelyNamedAmbientIsStillWatched() {
        let impostor = identity(pid: 6, name: "Ambient", path: "/tmp/Ambient",
                                signature: signature("com.evil", team: nil, leaf: nil, adHoc: true, runtime: false, notarized: false))
        let result = RaoAttributor.attribute(name: "Ambient", identity: impostor, parentPid: 1, appPids: [], touchesKnownPorts: false, app: app)
        #expect(result?.role == .app && result?.confidence == .processName)
    }
}

// MARK: - Classification

@Suite struct RaoClassifierTests {
    let classifier = RaoClassifier(app: .ambient)

    @Test func loopbackToKnownPortsIsLocal() {
        let result = classifier.classify(facts("Ambient", remote: "127.0.0.1", port: 47080, scope: .loopback, local: "127.0.0.1"),
                                         mode: .onDevice, hostnames: [], settings: [:])
        #expect(result.kind == .local && result.note.contains("Sewn") && !result.unknownLoopbackPort)
        let odd = classifier.classify(facts("Ambient", remote: "127.0.0.1", port: 9999, scope: .loopback, local: "127.0.0.1"),
                                      mode: .onDevice, hostnames: [], settings: [:])
        #expect(odd.kind == .local && odd.unknownLoopbackPort)
    }

    @Test func hostedServicesDependOnMode() {
        let mistral = facts("sewn-server")
        #expect(classifier.classify(mistral, mode: .signedIn, hostnames: ["api.mistral.ai"], settings: [:]).kind == .expected)
        let onDevice = classifier.classify(mistral, mode: .onDevice, hostnames: ["api.mistral.ai"], settings: [:])
        #expect(onDevice.kind == .unexpected && onDevice.note.contains("only when Signed in"))
        // The same host from the wrong process isn't covered by the rule.
        #expect(classifier.classify(facts("Ambient"), mode: .signedIn, hostnames: ["api.mistral.ai"], settings: [:]).kind == .expected)
    }

    @Test func modelDownloadIsExpectedOnceAndOnlyAsADownload() {
        let download = classifier.classify(facts("sewn-server", out: 2_000), mode: .onDevice,
                                           hostnames: ["cdn-lfs-us-1.hf.co"], settings: [:])
        #expect(download.kind == .expected && download.firstRun)
        let upload = classifier.classify(facts("sewn-server", out: 50 * 1_048_576), mode: .onDevice,
                                         hostnames: ["huggingface.co"], settings: [:])
        #expect(upload.kind == .unexpected && upload.note.contains("only receives"))
        let cdn = classifier.classify(facts("sewn-server"), mode: .onDevice,
                                      hostnames: ["server-1-2-3-4.fra56.r.cloudfront.net"], settings: [:])
        #expect(cdn.kind == .expected && cdn.broad)
        // Ambient itself has no business at HuggingFace.
        #expect(classifier.classify(facts("Ambient"), mode: .onDevice, hostnames: ["huggingface.co"], settings: [:]).kind == .unexpected)
    }

    @Test func pictureFetchesNeedSignInAndTheSetting() {
        let fetch = facts("Ambient")
        #expect(classifier.classify(fetch, mode: .signedIn, hostnames: ["images.example.com"], settings: [:]).broad)
        let off = classifier.classify(fetch, mode: .signedIn, hostnames: ["images.example.com"],
                                      settings: ["describeImagesThroughSewn": false])
        #expect(off.kind == .unexpected && off.note.contains("Describe pictures"))
        #expect(classifier.classify(fetch, mode: .onDevice, hostnames: ["images.example.com"], settings: [:]).kind == .unexpected)
    }

    @Test func unknownModeIsHeldToOnDeviceRules() {
        let result = classifier.classify(facts("sewn-server"), mode: .unknown, hostnames: ["api.mistral.ai"], settings: [:])
        #expect(result.kind == .unexpected && result.modeWasUnknown)
    }

    @Test func exposedListenersAreOutsideConsent() {
        let exposed = classifier.classify(facts("sewn-server", remote: "", port: nil, scope: .external, direction: .listening,
                                                local: "", localPort: 47080), mode: .onDevice, hostnames: [], settings: [:])
        #expect(exposed.kind == .unexpected && exposed.note.contains("every network interface"))
        let local = classifier.classify(facts("sewn-server", remote: "", port: nil, scope: .loopback, direction: .listening,
                                              local: "127.0.0.1", localPort: 47080), mode: .onDevice, hostnames: [], settings: [:])
        #expect(local.kind == .local)
    }
}

// MARK: - Identity audit

@Suite struct RaoIdentityAuditorTests {
    let app = RaoApp.ambient

    private func process(_ identity: ProcessIdentity?, role: RaoAttribution.Role, confidence: RaoAttribution.Confidence = .signature) -> RaoProcess {
        RaoProcess(pid: identity?.pid ?? 0, name: identity?.name ?? "?",
                   attribution: RaoAttribution(role: role, confidence: confidence, evidence: "test"),
                   identity: identity, parentName: nil)
    }

    private let sewn = identity(pid: 200, name: "sewn-server", path: "/Users/x/.rao/sewn/bin/sewn-server", parent: 100,
                                signature: signature("nyc.rao.ambient.sewn-server"))

    @Test func releaseBuildVerifies() {
        let findings = RaoIdentityAuditor.audit(app: app, processes: [process(released, role: .app), process(sewn, role: .helper("sewn-server"))], reference: nil)
        #expect(findings.filter { $0.severity == .verified }.count == 2)
        #expect(!findings.contains { $0.severity >= .warning })
    }

    @Test func impostorNamedAmbientRaisesAlarm() {
        let impostor = identity(pid: 300, name: "Ambient", path: "/tmp/Ambient",
                                signature: signature("com.example.tool", team: nil, leaf: nil, adHoc: true, runtime: false, notarized: false))
        let findings = RaoIdentityAuditor.audit(app: app, processes: [process(impostor, role: .app, confidence: .processName)], reference: nil)
        #expect(findings.contains { $0.severity == .alarm && $0.title.contains("isn't signed as nyc.rao.ambient") })
    }

    @Test func tamperedBinaryRaisesAlarm() {
        let tampered = identity(pid: 301, name: "Ambient", path: "/Applications/Ambient.app/Contents/MacOS/Ambient",
                                signature: signature("nyc.rao.ambient", valid: false))
        let findings = RaoIdentityAuditor.audit(app: app, processes: [process(tampered, role: .app)], reference: nil)
        #expect(findings.contains { $0.severity == .alarm && $0.title.contains("doesn't validate") })
    }

    @Test func claimingTheBundleIdIsNotEnoughWhenAReleaseIsInstalled() {
        let reference = InstalledReference(path: "/Applications/Ambient.app", version: "1.0.0", build: "1",
                                           signature: signature("nyc.rao.ambient"))
        let adHocClaimant = identity(pid: 302, name: "Ambient", path: "/tmp/Ambient",
                                     signature: signature("nyc.rao.ambient", team: nil, leaf: nil, adHoc: true, runtime: false, notarized: false))
        let findings = RaoIdentityAuditor.audit(app: app, processes: [process(adHocClaimant, role: .app)], reference: reference)
        #expect(findings.contains { $0.severity == .alarm && $0.title.contains("someone other than the installed") })
        let otherTeam = identity(pid: 303, name: "Ambient", path: "/tmp/Ambient", signature: signature("nyc.rao.ambient", team: "TEAMBBBBBB"))
        #expect(RaoIdentityAuditor.audit(app: app, processes: [process(otherTeam, role: .app)], reference: reference)
            .contains { $0.severity == .alarm })
    }

    @Test func developmentBuildsAreWarningsWithoutARelease() {
        let dev = identity(pid: 304, name: "thread", path: "/src/thread", parent: 1,
                           signature: signature("thread", team: nil, leaf: nil, adHoc: true, runtime: false, notarized: false))
        let findings = RaoIdentityAuditor.audit(app: app, processes: [process(dev, role: .helper("thread"), confidence: .portAffinity)], reference: nil)
        #expect(findings.contains { $0.severity == .warning && $0.title.contains("development build") })
        #expect(!findings.contains { $0.severity == .alarm })
    }

    @Test func mixedTeamsAmongReleasesIsAnAlarm() {
        let otherSewn = identity(pid: 201, name: "sewn-server", path: "/x", parent: 100,
                                 signature: signature("nyc.rao.ambient.sewn-server", team: "TEAMBBBBBB"))
        let findings = RaoIdentityAuditor.audit(app: app, processes: [process(released, role: .app), process(otherSewn, role: .helper("sewn-server"))], reference: nil)
        #expect(findings.contains { $0.severity == .alarm && $0.title.contains("different developers") })
    }
}

// MARK: - Ledger and trust level

@Suite struct TrustAssessorTests {
    let app = RaoApp.ambient
    let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    private func ledger() -> DayLedger {
        DayLedger(day: "2026-09-26", appId: "ambient", pelicanBuild: "test")
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: hour, minute: minute))!
    }

    private func flow(_ kind: FlowClassKind, scope: FlowScope = .external, at date: Date, out: UInt64 = 0, firstRun: Bool = false) -> LedgerFlow {
        LedgerFlow(id: UUID().uuidString, pid: 1, process: "sewn-server", socketOwner: nil, attribution: "test",
                   proto: .tcp4, direction: .outbound, scope: scope, localAddress: "10.0.0.5", localPort: 5,
                   remoteAddress: scope == .loopback ? "127.0.0.1" : "1.2.3.4", remotePort: 443, remoteHost: nil,
                   openedAt: date, closedAt: nil, bytesIn: 10, bytesOut: out, mode: .onDevice,
                   classification: FlowClassification(kind: kind, note: "n", firstRun: firstRun), seenBy: [.nstat])
    }

    @Test func quietObservedDayIsTrusted() {
        var day = ledger()
        day.observed = [ObservedInterval(start: at(8), end: at(18))]
        day.runs = [AppRun(pid: 1, startTime: 1, launchedAt: at(9), quitAt: at(17), version: "1.0.0", path: nil)]
        day.flows = [flow(.local, scope: .loopback, at: at(10))]
        let result = TrustAssessor.assess(day, app: app, now: at(19), captureDegraded: false, calendar: calendar)
        #expect(result.level == .trusted)
        #expect(result.summary.contains("ran for 8h 0m") && result.summary.contains("nothing left this Mac"))
    }

    @Test func unexpectedConnectionIsABreach() {
        var day = ledger()
        day.observed = [ObservedInterval(start: at(8), end: at(18))]
        day.flows = [flow(.unexpected, at: at(11), out: 4_096)]
        let result = TrustAssessor.assess(day, app: app, now: at(19), captureDegraded: false, calendar: calendar)
        #expect(result.level == .breach && result.unexpectedConnections == 1 && result.bytesLeftMac == 4_096)
    }

    @Test func runningWhileUnwatchedNeedsAReview() {
        var day = ledger()
        day.observed = [ObservedInterval(start: at(10), end: at(18))]
        day.runs = [AppRun(pid: 1, startTime: 1, launchedAt: at(9), quitAt: nil, version: nil, path: nil)]
        let result = TrustAssessor.assess(day, app: app, now: at(12), captureDegraded: false, calendar: calendar)
        #expect(result.level == .review)
        #expect(result.reasons.contains { $0.contains("while Pelican wasn't watching") && $0.contains("1h 0m") })
    }

    @Test func firstRunDownloadAndDegradedCaptureAreReviews() {
        var day = ledger()
        day.observed = [ObservedInterval(start: at(0), end: at(23))]
        day.runs = [AppRun(pid: 1, startTime: 1, launchedAt: at(9), quitAt: at(10), version: nil, path: nil)]
        day.flows = [flow(.expected, at: at(9), firstRun: true)]
        let result = TrustAssessor.assess(day, app: app, now: at(23), captureDegraded: true, calendar: calendar)
        #expect(result.level == .review)
        #expect(result.reasons.count == 2)
    }

    @Test func hourlyBucketsAndGaps() {
        var day = ledger()
        day.flows = [flow(.local, scope: .loopback, at: at(9, 5)), flow(.unexpected, at: at(9, 30), out: 7), flow(.expected, at: at(23, 59))]
        let buckets = day.hourly(calendar: calendar)
        #expect(buckets[9].local == 1 && buckets[9].unexpected == 1 && buckets[9].bytesOutExternal == 7)
        #expect(buckets[23].expected == 1)
        day.observed = [ObservedInterval(start: at(10), end: at(11)), ObservedInterval(start: at(12), end: at(13))]
        let gaps = day.unobserved(DateInterval(start: at(9), end: at(14)))
        #expect(gaps.map(\.duration) == [3600, 3600, 3600])
    }

    @Test func ledgerRoundTripsThroughJSON() throws {
        var day = ledger()
        day.flows = [flow(.expected, at: at(9))]
        day.consent = [ConsentEvent(at: at(8), mode: .onDevice, source: .detected, changes: [])]
        day.findings = [LedgerFinding(finding: RaoFinding(severity: .verified, title: "t", detail: "d"), firstSeen: at(8), lastSeen: at(9))]
        let data = try LedgerStore.encoder.encode(day)
        let decoded = try LedgerStore.decoder.decode(DayLedger.self, from: data)
        #expect(decoded.flows.first?.classification == day.flows.first?.classification)
        #expect(decoded.consent.first?.mode == .onDevice && decoded.findings.count == 1)
        #expect(decoded.mode(at: at(12)) == .onDevice)
    }

    @Test func storeSavesListsAndPrunes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pelican-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LedgerStore(root: root)
        for day in ["2026-09-24", "2026-09-25", "2026-09-26"] {
            try await store.save(DayLedger(day: day, appId: "ambient", pelicanBuild: "t"))
        }
        #expect(await store.days(appId: "ambient") == ["2026-09-26", "2026-09-25", "2026-09-24"])
        await store.prune(appId: "ambient", keep: 2)
        #expect(await store.days(appId: "ambient") == ["2026-09-26", "2026-09-25"])
        #expect(await store.load(appId: "ambient", day: "2026-09-25")?.day == "2026-09-25")
    }
}

// MARK: - Consent and report

@Suite struct ConsentAndReportTests {
    @Test func readsAmbientsSavedMode() throws {
        let store = try #require(RaoApp.ambient.consentStore)
        let plist: [String: Any] = ["state": ["onDeviceMode": true, "alwaysListeningEnabled": true,
                                              "describeImagesThroughSewn": false, "llmEngine": "local",
                                              "excludedBundleIDs": ["a", "b", "c", "d"]]]
        let snapshot = try #require(ConsentDetector.parse(plist, store: store, sourcePath: "/x"))
        #expect(snapshot.mode == .onDevice)
        #expect(snapshot.booleans["describeImagesThroughSewn"] == false)
        #expect(snapshot.settings.first { $0.key == "excludedBundleIDs" }?.value == "4 apps")
        var changed = plist
        changed["state"] = ["onDeviceMode": false, "alwaysListeningEnabled": true, "describeImagesThroughSewn": false,
                            "llmEngine": "mistral", "excludedBundleIDs": ["a", "b", "c", "d"]]
        let later = try #require(ConsentDetector.parse(changed, store: store, sourcePath: "/x"))
        #expect(later.changes(since: snapshot) == ["On-device mode: on → off", "Reply engine: local → mistral"])
        #expect(ConsentDetector.parse(["state": [:]], store: store, sourcePath: "/x") == nil)
    }

    @Test func reportCarriesVerdictReasonsAndData() throws {
        var day = DayLedger(day: "2026-09-26", appId: "ambient", pelicanBuild: "Pelican test")
        day.flows = [LedgerFlow(id: "f", pid: 1, process: "sewn-server", socketOwner: nil, attribution: "signed",
                                proto: .tcp4, direction: .outbound, scope: .external, localAddress: "10.0.0.5",
                                localPort: 5, remoteAddress: "1.2.3.4", remotePort: 443, remoteHost: "api.mistral.ai",
                                openedAt: Date(), closedAt: nil, bytesIn: 1, bytesOut: 2, mode: .onDevice,
                                classification: FlowClassification(kind: .unexpected, note: "allowed only | when signed in"),
                                seenBy: [.nstat])]
        let assessment = TrustAssessor.assess(day, app: .ambient, now: Date(), captureDegraded: false)
        let report = RaoReport(generatedAt: Date(), pelican: "Pelican test", macOS: "27", app: "Ambient",
                               appSite: "https://ambient.rao.nyc", day: day.day, assessment: assessment,
                               capture: ["NetworkStatistics events": "running"], consentNow: nil, declaredUsage: [:],
                               reference: nil, processes: [], ledger: day)
        let markdown = RaoReportRenderer.markdown(report)
        #expect(markdown.contains("**Outside your consent**"))
        #expect(markdown.contains("## Connections outside your consent"))
        #expect(markdown.contains("api.mistral.ai / 1.2.3.4:443"))
        #expect(markdown.contains("allowed only \\| when signed in"))
        let json = try RaoReportRenderer.json(report)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["app"] as? String == "Ambient")
    }
}
