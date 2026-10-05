import Foundation
import Testing
@testable import PelicanKit
@testable import PelicanRadio

/// Noon on 4 October 2026, local time.
private let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
private let wifiOn = RadioPosture(wifi: .on, bluetooth: .unknown, lockdown: .off)
private let wifiOff = RadioPosture(wifi: .off, bluetooth: .unknown, lockdown: .off)

@MainActor
private func makeStore(_ posture: RadioPosture = wifiOff, transports: Bool = false)
-> (RadioStore, ScriptedSystem, ScriptedSwitch) {
    let system = ScriptedSystem(posture, transports: transports)
    let switcher = ScriptedSwitch()
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pelican-radio-\(UUID().uuidString)")
    let store = RadioStore(system: system, source: ScriptedSource(), store: DayFileStore(folder: "radio", root: root),
                           switcher: switcher, now: noon)
    store.setObserving(true, at: noon)
    return (store, system, switcher)
}

@Suite @MainActor struct SwitchOffTests {

    @Test func switchingOffRecordsWhatWasAskedAndStartsTheCheck() async {
        let (store, _, switcher) = makeStore()
        await store.turnOff(wifi: true, services: ["USB 10/100/1000 LAN"], bluetooth: false, at: noon)

        #expect(switcher.isWiFiOn == false)
        #expect(switcher.asked.map(\.on) == [false])
        let quiet = store.quiet
        #expect(quiet?.wifi == true)
        #expect(quiet?.services == ["USB 10/100/1000 LAN"])
        #expect(quiet?.since == noon)
        #expect(store.quietStanding == .holding(since: noon))
        // It survives a restart, because it is written into the day.
        #expect(store.day.quiet == quiet)
    }

    @Test func aDismissedAuthorizationIsNotAClaimThatAnythingIsOff() async {
        let (store, _, switcher) = makeStore()
        switcher.servicesOutcome = .cancelled
        await store.turnOff(wifi: true, services: ["Thunderbolt Bridge"], bluetooth: false, at: noon)

        // Wi-Fi went off; the wired service did not, and is not claimed.
        #expect(store.quiet?.wifi == true)
        #expect(store.quiet?.services.isEmpty == true)
        #expect(store.lastSwitch?.contains("dismissed the authorization prompt") == true)
    }

    @Test func nothingIsRecordedWhenEverySwitchFails() async {
        let (store, _, switcher) = makeStore()
        switcher.wifiOutcome = .failed("Wi-Fi is managed by a profile")
        await store.turnOff(wifi: true, services: [], bluetooth: false, at: noon)
        #expect(store.quiet == nil)
        #expect(store.quietStanding == .notAsked)
        #expect(store.lastSwitch?.contains("managed by a profile") == true)
    }

    @Test func somethingSwitchedBackOnIsAFindingAndBreaksTheCheck() async {
        let (store, system, switcher) = makeStore(wifiOff)
        await store.turnOff(wifi: true, services: ["Thunderbolt Bridge"], bluetooth: false, at: noon)
        for step in stride(from: 1.0, through: 15, by: 1) { await store.tick(now: noon + step) }
        #expect(store.quietStanding == .holding(since: noon))

        // Something outside Pelican puts both back.
        system.set(wifiOn)
        switcher.reenable("Thunderbolt Bridge")
        // Not reported straight away: a posture that has only just changed is not judged.
        await store.tick(now: noon + 16)
        #expect(store.day.findings.filter { $0.kind == .turnedBackOn }.isEmpty)

        for step in stride(from: 17.0, through: 30, by: 1) { await store.tick(now: noon + step) }
        let turnedBackOn = store.day.findings.filter { $0.kind == .turnedBackOn }
        #expect(Set(turnedBackOn.map(\.subject)) == ["Wi-Fi", "Thunderbolt Bridge"])
        #expect(turnedBackOn.allSatisfy { $0.kind.isContradiction })
        #expect(turnedBackOn.allSatisfy { $0.detail.contains("Pelican did not do that") })
        #expect(store.quietStanding == .broken(2))
        #expect(store.standing == .contradiction(2))
        // Being on again is one fact that went on being true, not one event per check: it is
        // counted once, and only its end moves.
        #expect(turnedBackOn.allSatisfy { $0.count == 1 })
        #expect(turnedBackOn.contains { $0.lastSeen > $0.firstSeen })
    }

    /// The regression this exists for: switching Wi-Fi off was itself reported as Wi-Fi being
    /// switched back on, because the check ran against a posture read before the switch.
    @Test func switchingOffIsNeverItselfReportedAsABreak() async {
        let (store, system, _) = makeStore(wifiOn)
        // The Mac still reports Wi-Fi on at the moment of the switch, as it does in life.
        await store.turnOff(wifi: true, services: ["USB 10/100/1000 LAN"], bluetooth: false, at: noon)
        #expect(store.day.findings.isEmpty)
        #expect(store.quietStanding == .holding(since: noon))

        // macOS catches up a moment later; a whole minute of ticks follows.
        system.set(wifiOff)
        for step in stride(from: 1.0, through: 60, by: 1) { await store.tick(now: noon + step) }
        #expect(store.day.findings.isEmpty)
        #expect(store.quietStanding == .holding(since: noon))
    }

    /// The same staleness the other way round: the counters move the instant Wi-Fi comes back,
    /// and a posture read seconds earlier would call that transmitting while off.
    @Test func puttingBackIsNeverReportedAsABreak() async {
        let (store, system, _) = makeStore(wifiOff, transports: true)
        await store.turnOff(wifi: true, services: [], bluetooth: false, at: noon)
        for step in stride(from: 1.0, through: 20, by: 1) { await store.tick(now: noon + step) }
        #expect(store.quietStanding == .holding(since: noon))

        await store.restore()
        #expect(store.quiet == nil)
        // Wi-Fi is on again and its radio is busy at once, as it is after any reconnection.
        system.set(wifiOn)
        system.move(.wifiAirtime, .out, by: 23_188)
        system.move(.wifiBus, .out, by: 748)
        system.send(40)
        for step in stride(from: 21.0, through: 40, by: 1) { await store.tick(now: noon + step) }

        #expect(store.day.findings.isEmpty)
        #expect(store.standing != .contradiction(1))
    }

    @Test func packetsOnASwitchedOffInterfaceAreAFinding() async {
        let (store, system, _) = makeStore(wifiOff)
        await store.turnOff(wifi: false, services: ["USB 10/100/1000 LAN"], bluetooth: false, at: noon)
        // Two readings, both after the posture has settled, before anything is judged.
        for step in stride(from: 11.0, through: 29, by: 6) { await store.tick(now: noon + step) }
        system.send(9, on: "en8")
        await store.tick(now: noon + 35)

        let finding = store.day.findings.first { $0.kind == .movedWhileSwitchedOff }
        #expect(finding?.subject == "en8")
        #expect(finding?.count == 9)
        #expect(finding?.detail.contains("after you switched “USB 10/100/1000 LAN” off") == true)
        #expect(store.quietStanding == .broken(1))
    }

    @Test func dataIntoTheBluetoothChipAfterYouSwitchedItOffIsAFinding() async {
        let (store, system, _) = makeStore(wifiOff, transports: true)
        await store.tick(now: noon)                       // baseline
        await store.turnOff(wifi: false, services: [], bluetooth: true, at: noon + 1)
        await store.tick(now: noon + 2)
        system.move(.acl, .out, by: 24)
        await store.tick(now: noon + 3)

        let finding = store.day.findings.first { $0.kind == .movedWhileSwitchedOff }
        #expect(finding?.subject == "Bluetooth chip")
        #expect(finding?.count == 24)
        #expect(finding?.evidence == .counted(source: "the Bluetooth chip's driver"))
        #expect(store.quietStanding == .broken(1))
    }

    @Test func puttingBackOnlyEnablesWhatPelicanDisabled() async {
        let (store, _, switcher) = makeStore()
        await store.turnOff(wifi: true, services: ["Thunderbolt Bridge"], bluetooth: false, at: noon)
        await store.restore()

        #expect(switcher.isWiFiOn)
        #expect(switcher.asked.last?.names == ["Thunderbolt Bridge"])
        #expect(switcher.asked.last?.on == true)
        // The service that was never switched off is not touched.
        #expect(switcher.asked.allSatisfy { !$0.names.contains("USB 10/100/1000 LAN") })
        #expect(store.quiet == nil)
        #expect(store.quietStanding == .notAsked)
    }

    @Test func aDismissedPutBackKeepsTheCheckRunning() async {
        let (store, _, switcher) = makeStore()
        await store.turnOff(wifi: false, services: ["Thunderbolt Bridge"], bluetooth: false, at: noon)
        switcher.servicesOutcome = .cancelled
        await store.restore()
        #expect(store.quiet != nil)
        #expect(store.quietStanding == .holding(since: noon))
    }

    @Test func whatYouSwitchedOffStaysOffAcrossMidnight() async {
        let late = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 23, minute: 59, second: 50))!
        let system = ScriptedSystem(wifiOff)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pelican-radio-\(UUID().uuidString)")
        let store = RadioStore(system: system, source: ScriptedSource(), store: DayFileStore(folder: "radio", root: root),
                               switcher: ScriptedSwitch(), now: late)
        store.setObserving(true, at: late)
        await store.turnOff(wifi: true, services: [], bluetooth: false, at: late)
        await store.tick(now: late + 20)

        #expect(store.day.day == "2026-10-05")
        #expect(store.day.quiet?.wifi == true)
        #expect(store.day.quiet?.since == late)
        #expect(store.quietStanding == .holding(since: late))
    }
}

@Suite struct NetworkSwitchQuotingTests {

    @Test func aServiceNameCanNeverBeReadAsShellSyntax() {
        #expect(LiveNetworkSwitch.shellQuoted("Thunderbolt Bridge") == "'Thunderbolt Bridge'")
        #expect(LiveNetworkSwitch.shellQuoted("Ada's Ethernet") == #"'Ada'\''s Ethernet'"#)
        #expect(LiveNetworkSwitch.shellQuoted("x; rm -rf /") == "'x; rm -rf /'")
        #expect(LiveNetworkSwitch.shellQuoted("$(whoami)") == "'$(whoami)'")
    }

    @Test func theCommandIsQuotedAgainForAppleScript() {
        #expect(LiveNetworkSwitch.appleScriptQuoted(#"say "hi""#) == #""say \"hi\"""#)
        #expect(LiveNetworkSwitch.appleScriptQuoted(#"back\slash"#) == #""back\\slash""#)
    }
}
