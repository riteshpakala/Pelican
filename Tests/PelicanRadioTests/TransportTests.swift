import Foundation
import Testing
@testable import PelicanKit
@testable import PelicanRadio

/// The drivers' channel names, as IOReport gives them on macOS 27.0 — padding included.
private let skywalkQueue = "I/F AppleConvergedIPCSkywalkInterface, Queue ID 0"

@Suite struct TransportCatalogTests {

    private func classify(_ driver: String, _ protocolName: String? = nil, _ group: String, _ subgroup: String,
                          _ name: String) -> (TransportLink, TransportDirection, String?)? {
        TransportCatalog.classify(driver: driver, bluetoothProtocol: protocolName, group: group, subgroup: subgroup, name: name)
            .map { ($0.link, $0.direction, $0.reason) }
    }

    @Test func readsTheBluetoothChipsChannelsByProtocol() {
        let aclOut = classify("IOSkywalkKernelPipeBSDClient", "acl", "TX Completion Queue", skywalkQueue, "Pkt Cnt")
        #expect(aclOut?.0 == .acl && aclOut?.1 == .out)
        let hciIn = classify("IOSkywalkKernelPipeBSDClient", "hci", "RX Completion Queue", skywalkQueue, "Pkt Cnt")
        #expect(hciIn?.0 == .hci && hciIn?.1 == .in)
        let isoOut = classify("IOSkywalkKernelPipeBSDClient", "iso", "TX Completion Queue", skywalkQueue, "Pkt Cnt")
        #expect(isoOut?.0 == .iso)
    }

    @Test func ignoresPipesThatAreNotBluetoothsAndCountersThatAreNotTraffic() {
        // A Skywalk pipe outside the Bluetooth module, or its debug channel.
        #expect(classify("IOSkywalkKernelPipeBSDClient", nil, "TX Completion Queue", skywalkQueue, "Pkt Cnt") == nil)
        #expect(classify("IOSkywalkKernelPipeBSDClient", "debug", "TX Completion Queue", skywalkQueue, "Pkt Cnt") == nil)
        // Submission queues would count each packet a second time; Packet Count is a gauge.
        #expect(classify("IOSkywalkKernelPipeBSDClient", "acl", "TX Submission Queue", skywalkQueue, "Pkt Cnt") == nil)
        #expect(classify("IOSkywalkKernelPipeBSDClient", "acl", "TX Completion Queue", skywalkQueue, "Packet Count") == nil)
        #expect(classify("SomeOtherDriver", nil, "TX Completion Queue", skywalkQueue, "Pkt Cnt") == nil)
    }

    @Test func readsInterruptsAntennaRequestsAndTheWiFiChip() {
        let irq = classify("bluetooth-pcie", nil, "Interrupt Statistics (by index)", "bluetooth-pcie 0",
                           "               First Level Interrupt Handler Count")
        #expect(irq?.0 == .bluetoothInterrupts && irq?.1 == .in)
        #expect(classify("bluetooth-pcie", nil, "Interrupt Statistics (by index)", "bluetooth-pcie 0",
                         "              Second Level Interrupt Handler Count") == nil)

        let requests = classify("IO80211ReporterProxy", nil, "BT Coex", "Counters", "Antenna Requests")
        #expect(requests?.0 == .bluetoothAntenna && requests?.2 == nil)
        let scan = classify("IO80211ReporterProxy", nil, "BT Coex", "Antenna Request Reason", "BLE Scan")
        #expect(scan?.0 == .bluetoothAntenna && scan?.2 == "BLE Scan")

        let airtime = classify("IO80211ReporterProxy", nil, "WLAN Power", "Phy Activity", "Radio Tx Dur")
        #expect(airtime?.0 == .wifiAirtime && airtime?.1 == .out)
        let doorbells = classify("AppleBCMWLANBusInterfacePCIe", nil, "AppleBCMWLANBusInterfacePCIe", "Bus Events",
                                 "                                h2d Doorbell Rings")
        #expect(doorbells?.0 == .wifiBus && doorbells?.1 == .out)
        let interrupts = classify("AppleBCMWLANBusInterfacePCIe", nil, "AppleBCMWLANBusInterfacePCIe", "Bus Events",
                                  "                             d2h interrupt Counter")
        #expect(interrupts?.0 == .wifiBus && interrupts?.1 == .in)
    }

    @Test func splitsADriverNameFromItsRegistryID() {
        let pipe = TransportCatalog.split(driverName: "IOSkywalkKernelPipeBSDClient <id 0x100001107>")
        #expect(pipe.name == "IOSkywalkKernelPipeBSDClient" && pipe.registryID == 0x100001107)
        let pcie = TransportCatalog.split(driverName: "bluetooth-pcie <id 0x100000cdc>")
        #expect(pcie.name == "bluetooth-pcie" && pcie.registryID == 0x100000cdc)
        #expect(TransportCatalog.split(driverName: "bluetooth-pcie").registryID == nil)
    }
}

@Suite struct TransportMeterTests {

    private func snapshot(_ values: [(String, TransportLink, TransportDirection, String?, Int64)]) -> TransportSnapshot {
        TransportSnapshot(counters: values.map { TransportCounter(key: $0.0, link: $0.1, direction: $0.2, reason: $0.3, value: $0.4) },
                          status: .running)
    }

    @Test func theFirstReadingOnlySetsTheBaseline() {
        var meter = TransportMeter()
        #expect(meter.read(snapshot([("a", .acl, .out, nil, 5_000)])).isEmpty)
        let moved = meter.read(snapshot([("a", .acl, .out, nil, 5_036)]))
        #expect(moved.count(.acl, .out) == 36)
        #expect(moved.dataToBluetooth == 36)
    }

    @Test func causesAreKeptApartFromTheTotal() {
        var meter = TransportMeter()
        _ = meter.read(snapshot([("total", .bluetoothAntenna, .out, nil, 10), ("scan", .bluetoothAntenna, .out, "BLE Scan", 4)]))
        let moved = meter.read(snapshot([("total", .bluetoothAntenna, .out, nil, 15), ("scan", .bluetoothAntenna, .out, "BLE Scan", 7)]))
        #expect(moved.count(.bluetoothAntenna, .out) == 5)
        #expect(moved.reasons == ["BLE Scan": 3])
    }

    @Test func aRestartedCounterIsANewBaselineNeverANegativeCount() {
        var meter = TransportMeter()
        _ = meter.read(snapshot([("a", .hci, .in, nil, 900)]))
        #expect(meter.read(snapshot([("a", .hci, .in, nil, 12)])).isEmpty)
        #expect(meter.read(snapshot([("a", .hci, .in, nil, 20)])).count(.hci, .in) == 8)
    }

    @Test func aChannelFoundLaterIsCountedFromWhenItWasFound() {
        var meter = TransportMeter()
        _ = meter.read(snapshot([("a", .hci, .in, nil, 1)]))
        // Bluetooth switched on: a new pipe appears with its own counters.
        #expect(meter.read(snapshot([("a", .hci, .in, nil, 1), ("b", .acl, .out, nil, 40)])).isEmpty)
        #expect(meter.read(snapshot([("a", .hci, .in, nil, 1), ("b", .acl, .out, nil, 45)])).count(.acl, .out) == 5)
    }
}

/// Noon on 4 October 2026, local time.
private let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!

@MainActor
private func makeStore(_ posture: RadioPosture) -> (RadioStore, ScriptedSystem) {
    let system = ScriptedSystem(posture, transports: true)
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pelican-radio-\(UUID().uuidString)")
    let store = RadioStore(system: system, source: ScriptedSource(), store: DayFileStore(folder: "radio", root: root), now: noon)
    store.setObserving(true, at: noon)
    return (store, system)
}

@Suite @MainActor struct RadioStoreTransportTests {

    @Test func dataIntoTheBluetoothChipIsItemisedWhileLockedDown() async {
        let (store, system) = makeStore(RadioPosture(wifi: .off, bluetooth: .on, lockdown: .on))
        await store.tick(now: noon)                       // baseline
        system.move(.acl, .out, by: 36)
        system.move(.hci, .out, by: 2)
        system.move(.hci, .in, by: 47)
        await store.tick(now: noon + 1)

        let findings = store.day.findings.filter { $0.kind == .dataIntoBluetoothWhileLockedDown }
        #expect(Set(findings.map(\.subject)) == ["ACL data", "HCI"])
        #expect(findings.first { $0.subject == "ACL data" }?.count == 36)
        #expect(findings.allSatisfy { $0.evidence == .counted(source: "the Bluetooth chip's driver") })
        let minute = store.day.transportMinute(EpochMinute.of(noon))
        #expect(minute?.dataToBluetooth == 36)
        #expect(minute?.lockedDown == true)
        #expect(store.day.total(.hci, .in) == 47)
        #expect(store.standing == .lockedDown(minutes: 1))
        #expect(store.latestMovement.count(.acl, .out) == 36)
        #expect(store.lastMoved["acl"] == noon + 1)
    }

    @Test func onlyDataTowardTheRadioMakesASendingMinute() async {
        let (store, system) = makeStore(RadioPosture(wifi: .on, bluetooth: .on, lockdown: .off))
        await store.tick(now: noon)
        system.move(.acl, .in, by: 12)
        system.move(.bluetoothInterrupts, .in, by: 80)
        system.move(.hci, .out, by: 1)
        await store.tick(now: noon + 1)
        #expect(store.day.transmittingMinutes == 0)
        #expect(store.day.total(.bluetoothInterrupts, .in) == 80)
        #expect(store.standing == .nothingReported)

        system.move(.acl, .out, by: 5)
        await store.tick(now: noon + 2)
        #expect(store.standing == .transmitting(minutes: 1))
        #expect(store.day.findings.isEmpty)
    }

    @Test func whatMovedWhileAsleepIsCountedButNotTimed() async {
        let (store, system) = makeStore(RadioPosture(wifi: .on, bluetooth: .on, lockdown: .off))
        await store.tick(now: noon)
        await store.tick(now: noon + 1)
        system.move(.acl, .out, by: 500)
        await store.tick(now: noon + 100)               // woke from sleep
        #expect(store.day.away(.acl, .out) == 500)
        #expect(store.day.total(.acl, .out) == 0)
        #expect(store.day.transportMinutes.isEmpty)

        system.move(.acl, .out, by: 5)
        await store.tick(now: noon + 101)
        #expect(store.day.total(.acl, .out) == 5)
        #expect(store.day.away(.acl, .out) == 500)
    }

    @Test func whatMovedWhilePausedIsCountedButNotTimed() async {
        let (store, system) = makeStore(RadioPosture(wifi: .on, bluetooth: .on, lockdown: .off))
        await store.tick(now: noon)
        store.setObserving(false, at: noon + 2)
        system.move(.hci, .out, by: 30)
        await store.tick(now: noon + 5)
        await store.tick(now: noon + 10)
        store.setObserving(true, at: noon + 12)
        await store.tick(now: noon + 12)
        #expect(store.day.away(.hci, .out) == 30)
        #expect(store.day.total(.hci, .out) == 0)
    }

    @Test func wifiAirtimeWithWiFiReportedOffIsAContradictionOnceSettled() async {
        let (store, system) = makeStore(RadioPosture(wifi: .off, bluetooth: .unknown, lockdown: .off))
        await store.tick(now: noon)
        system.move(.wifiAirtime, .out, by: 900)        // still switching off: not judged
        await store.tick(now: noon + 3)
        #expect(store.day.contradictions.isEmpty)

        await store.tick(now: noon + 5)
        await store.tick(now: noon + 10)
        system.move(.wifiAirtime, .out, by: 3_000)
        system.move(.wifiBus, .out, by: 4)
        await store.tick(now: noon + 11)
        let airtime = store.day.findings.first { $0.kind == .wifiTransmittedWhileOff }
        #expect(airtime?.count == 3_000)
        #expect(airtime?.kind.isContradiction == true)
        let bus = store.day.findings.first { $0.kind == .wifiChipBusyWhileOff }
        #expect(bus?.count == 4)
        #expect(bus?.kind.isContradiction == false)
        #expect(store.standing == .contradiction(1))
    }

    @Test func blindOnlyWhenNeitherSourceCanBeRead() {
        var day = RadioDay(day: "2026-10-04", pelicanBuild: "test")
        day.transportLinks = ["hci"]
        #expect(RadioAssessor.standing(day: day, observing: true, source: .unavailable("not an admin"),
                                       transports: .running) == .nothingReported)
        #expect(RadioAssessor.standing(day: day, observing: true, source: .unavailable("not an admin"),
                                       transports: .unavailable("no counters")) == .blind("not an admin; no counters"))
    }
}

@Suite struct IOReportTransportsTests {

    /// On any Mac: the reader loads without root, and either finds the Bluetooth chip's channels
    /// or says why not — never a silent nothing.
    @Test func readsTheDriversOwnCountersOrSaysWhyNot() {
        let reader = IOReportTransports()
        let first = reader.snapshot()
        switch first.status {
        case .running:
            #expect(first.links.contains(.hci))
            #expect(first.counters.allSatisfy { $0.value >= 0 })
            // A second reading within the refresh interval reuses the subscription.
            #expect(reader.snapshot().links == first.links)
        case .unavailable(let reason):
            #expect(!reason.isEmpty)
        case .stopped:
            Issue.record("a snapshot is never merely stopped")
        }
    }
}
