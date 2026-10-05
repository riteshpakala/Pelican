import Foundation
import Testing
@testable import PelicanKit
@testable import PelicanRadio

/// One `log stream --style ndjson` line of the shape macOS 27 writes. The format strings are
/// copied from a real capture; every name, address, identifier and pointer is made up.
func logLine(_ category: String, _ format: String, _ message: String, process: String = "bluetoothd",
             timestamp: String = "2026-10-04 14:03:11.250000-0400") -> String {
    let entry: [String: Any] = [
        "timestamp": timestamp,
        "messageType": "Default",
        "subsystem": "com.apple.bluetooth",
        "category": category,
        "formatString": format,
        "eventMessage": message,
        "processImagePath": "/usr/sbin/\(process)",
        "processID": 398,
        "threadID": 1234,
    ]
    let data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

enum Fixture {
    static let scanForProcess = logLine(
        "WirelessProximity", "Start scanning for process %{public}@ (%d) with %{public}@",
        "Start scanning for process sharingd (666) with scan request of type 16, blob: {length = 0, bytes = 0x}, mask {length = 0, bytes = 0x}, active: 0, duplicates: 0, screen on")
    static let activeScanForProcess = logLine(
        "WirelessProximity", "Start scanning for process %{public}@ (%d) with %{public}@",
        "Start scanning for process sharingd (666) with scan request of type 7, blob: {length = 0, bytes = 0x}, mask {length = 0, bytes = 0x}, active: 1, duplicates: 0, screen on")
    static let startRequest = logLine(
        "Server.LE.Scan", "%{public}s",
        "Received 'start Unspecified scan' request  , without duplicates, duration:unlimited, on 1M PHY scan timing 30/60  scanLevel=3 from session \"com.apple.bluetoothd-central-398-3\"")
    static let stopRequest = logLine(
        "Server.LE.Scan",
        "Received 'stop scan' request from session \"%{public}s\" (%{public}s) updateScanParams:%{public}s shouldUpdateState:%{public}s",
        "Received 'stop scan' request from session \"CBDaemon-0x1A2B3C4D\" (CBDaemon) updateScanParams:YES shouldUpdateState:YES")
    static let passiveScan = logLine(
        "Server.LE.Scan",
        "%{public}sStarting %{public}s scan (%{public}s) with duplicate filter %{public}s scNeed=%d stateO=%d, retainDups=%d fScanFiltersNeedUpdating=%{public}s",
        "Starting passive scan (300.00ms/30.00ms) with duplicate filter enabled scNeed=1 stateO=0, retainDups=0 fScanFiltersNeedUpdating=YES")
    static let activeScan = logLine(
        "Server.LE.Scan",
        "%{public}sStarting %{public}s scan (%{public}s) with duplicate filter %{public}s scNeed=%d stateO=%d, retainDups=%d fScanFiltersNeedUpdating=%{public}s",
        "Starting active scan (60.00ms/30.00ms) with duplicate filter enabled scNeed=1 stateO=0, retainDups=0 fScanFiltersNeedUpdating=YES")
    static let scanParams = logLine(
        "Server.LE.Scan", "ScanParams: %{public}@",
        "ScanParams: [CBDaemon-0x1A2B3C4D] AP:0 AD:0(30/300) AS:0 RAS:0 DMN:1 FG:0 ADVBF:0 pBT:0|[com.apple.locationd-central-382-0] AP:0 AD:0(30/300) AS:0")
    static let scanParamsSummary = logLine(
        "Server.LE.Scan", "ScanParams: numScanAgents %lu, combined params %{public}@",
        "ScanParams: numScanAgents 4, combined params AD:0 AS:0 MSL:3 (30/60) PSV:1")
    static let xpcRequest = logLine(
        "Server.XPC", "Received XPC message \"%{public}s\" from session \"%{public}s\"",
        "Received XPC message \"CBMsgIdScan\" from session \"com.apple.bluetoothd-central-398-3\"")
    static let frameworkRequest = logLine(
        "Server.XPC", "Received MBFramework XPC message \"%{public}s\" from session \"%{public}s\"",
        "Received MBFramework XPC message \"kCBMsgIdDeviceFromIdentifierMsg\" from session \"com.apple.sharingd-MBF-666-563\"")
    static let indication = logLine(
        "Server.App", "Dispatching GATT indication for device \"%{public}@\" to session \"%{public}s\"",
        "Dispatching GATT indication for device \"00000000-0000-0000-0000-000000000001\" to session \"com.apple.BTLEServer-central-606-15\"")
    static let quietLE = logLine(
        "Server.Core",
        "Le [0x%x]: time %3d, coex %3d, rssi %3d, tx [S=%3d:F=%3d], rx [S=%3d:F=%3d], 1M {rx %d, tx %d}, 2M {rx %d, tx %d}",
        "Le [0x47]: time  39, coex   2, rssi -52, tx [S=  0:F=  0], rx [S=  0:F=  0], 1M {rx 0, tx 0}, 2M {rx 0, tx 0}")
    static let busyClassic = logLine(
        "Server.Core",
        "Classic [0x%x]: time %3d, coex %3d, rssi %3d, tx [S=%3d:F=%3d], rx [S=%3d:F=%3d], Pkt Tx{%d %d %d}{%d %d %d}{%d %d %d} Rx{%d %d %d}{%d %d %d}{%d %d %d}",
        "Classic [0x23]: time  21, coex   3, rssi -50, tx [S=  0:F= 17], rx [S=  2:F=  0], Pkt Tx{0 0 0}{0 0 0}{0 0 0} Rx{0 0 0}{0 0 0}{0 0 0}")
    static let audio = logLine(
        "Server.Audio",
        "BeamformingReport: Packets on {Ant0, Ant1, Beamforming} = {%3d, %3d, %3d}; Total tx packets = %3d, Total retx packets = %3d; Total ePA packets = %3d; Total packets beamforming+ePA = %3d",
        "BeamformingReport: Packets on {Ant0, Ant1, Beamforming} = {  0,  63,   0}; Total tx packets =  63, Total retx packets =  24; Total ePA packets =   0; Total packets beamforming+ePA =   0")
    static let connection = logLine("Server.MacCoex", "Adding LE Connection %@", "Adding LE Connection <private>")
    static let accessoryMessage = logLine(
        "Server.Accessory", "Device %{public}s Custom msg received [%@], len: %d",
        "Device AA:BB:CC:DD:EE:01 Custom msg received [{length = 3, bytes = 0x010203}], len: 3")
    static let accessoryEcho = logLine(
        "CBStackAccessoryMonitor", "%{public}s",
        "Custom message received for device CBDevice 00000000-0000-0000-0000-000000000004, BDA <private>")
    static let command = logLine("Server.Core", "Sending: %{public}s", "Sending: BD_VSC_LE_META_ADV_PCF_FEATURE_SEL")
    static let wlanOn = logLine(
        "Server.Core",
        "Desense: WLAN Status: %@, isWiFiAssociated: %@, wiFiAssociatedBand2GHz: %@, wiFiAssociatedBand5GHz: %@",
        "Desense: WLAN Status: ON, isWiFiAssociated: No, wiFiAssociatedBand2GHz: No, wiFiAssociatedBand5GHz: No")
    static let deviceFound = logLine(
        "CBDiscovery", "Device found: %{public}@",
        "Device found: CBDevice 00000000-0000-0000-0000-000000000002, BDA <private>, Nm <private> , RSSI -79, Ch 38",
        process: "milod")
    /// A line whose message carries a person's name and a device address — what must never be
    /// kept or printed.
    static let personal = logLine(
        "BTSmartRoutingDaemon", "%{public}s",
        "NearbySourceDevice updated: ID 00000000-0000-0000-0000-000000000003, Name 'Ada’s phone', address AA:BB:CC:DD:EE:FF, audio score 1 (Idle)",
        process: "audioaccessoryd")
    static let personalDetails = ["Ada’s phone", "AA:BB:CC:DD:EE:FF", "00000000-0000-0000-0000-000000000003"]
}

@Suite struct BluetoothLogParserTests {

    private func event(_ line: String) -> BluetoothEvent? {
        if case .event(let event, _, _) = BluetoothLogParser.parse(line) { return event }
        return nil
    }

    @Test func readsWhichProcessAskedForAScanAndWhetherItTransmits() {
        #expect(event(Fixture.scanForProcess) == .scanRequested(.process(name: "sharingd", pid: 666), active: false))
        #expect(event(Fixture.scanForProcess)?.transmission == nil)
        let active = event(Fixture.activeScanForProcess)
        #expect(active == .scanRequested(.process(name: "sharingd", pid: 666), active: true))
        #expect(active?.transmission?.subject == "sharingd (pid 666)")
    }

    @Test func namesTheClientFromItsSession() {
        #expect(event(Fixture.startRequest) == .scanRequested(.process(name: "bluetoothd", pid: 398), active: nil))
        #expect(event(Fixture.stopRequest) == .scanStopRequested(.session("CBDaemon-0x…")))
        #expect(event(Fixture.xpcRequest) == .request(.process(name: "bluetoothd", pid: 398), message: "CBMsgIdScan"))
        #expect(event(Fixture.frameworkRequest)
                == .request(.process(name: "sharingd", pid: 666), message: "kCBMsgIdDeviceFromIdentifierMsg"))
        #expect(event(Fixture.indication) == .indication(.process(name: "BTLEServer", pid: 606)))
        #expect(event(Fixture.scanParams)
                == .scanAgents([.session("CBDaemon-0x…"), .process(name: "locationd", pid: 382)]))
    }

    @Test func aPassiveScanListensAndAnActiveOneTransmits() {
        #expect(event(Fixture.passiveScan) == .scanStarted(active: false))
        #expect(event(Fixture.passiveScan)?.transmission == nil)
        #expect(event(Fixture.activeScan) == .scanStarted(active: true))
        #expect(event(Fixture.activeScan)?.transmission != nil)
    }

    @Test func keepsLinkCountersAsPrintedAndCountsOnlyNonZeroOnesAsSending() {
        #expect(event(Fixture.quietLE) == .linkReport(.le, handle: "0x47", txSuccess: 0, txFailed: 0, rxSuccess: 0, rxFailed: 0))
        #expect(event(Fixture.quietLE)?.transmission == nil)
        let classic = event(Fixture.busyClassic)
        #expect(classic == .linkReport(.classic, handle: "0x23", txSuccess: 0, txFailed: 17, rxSuccess: 2, rxFailed: 0))
        #expect(classic?.transmission?.packets == 17)
        #expect(event(Fixture.audio) == .audioReport(txPackets: 63, retransmitted: 24))
        #expect(event(Fixture.audio)?.transmission?.packets == 63)
        // Repeats every few seconds for a connection already up: not counted as sending.
        #expect(event(Fixture.connection) == .connectionAdded(.le))
        #expect(event(Fixture.connection)?.transmission == nil)
    }

    @Test func countsAccessoryMessagesOnceAsReceived() {
        #expect(event(Fixture.accessoryMessage) == .accessoryMessage)
        #expect(event(Fixture.accessoryMessage)?.transmission == nil)
        #expect(event(Fixture.accessoryEcho) == .echo)
    }

    @Test func readsControllerCommandsWlanStatusAndHeardDevices() {
        #expect(event(Fixture.command) == .controllerCommand("BD_VSC_LE_META_ADV_PCF_FEATURE_SEL"))
        #expect(event(Fixture.command)?.transmission == nil)
        #expect(event(Fixture.wlanOn) == .wlanStatus(.on))
        #expect(event(Fixture.deviceFound) == .devicesHeard(1))
        #expect(event(Fixture.deviceFound)?.transmission == nil)
    }

    @Test func countsWhatItCannotReadByFormatNeverByMessage() {
        guard case .uninterpreted(let key) = BluetoothLogParser.parse(Fixture.scanParamsSummary) else {
            Issue.record("expected an uninterpreted line"); return
        }
        #expect(key == "bluetoothd Server.LE.Scan: ScanParams: numScanAgents %lu, combined params %{public}@")
        guard case .uninterpreted(let personal) = BluetoothLogParser.parse(Fixture.personal) else {
            Issue.record("expected an uninterpreted line"); return
        }
        for detail in Fixture.personalDetails { #expect(!personal.contains(detail)) }
    }

    @Test func theBannerIsNotJSON() {
        #expect(BluetoothLogParser.parse("Filtering the log data using \"subsystem == \\\"com.apple.bluetooth\\\"\"") == .notJSON)
        #expect(BluetoothLogParser.parse("") == .notJSON)
        #expect(BluetoothLogParser.parse("{not json") == .notJSON)
    }

    @Test func readsTheTimestampWithItsZone() throws {
        guard case .event(_, let at, _) = BluetoothLogParser.parse(Fixture.command) else {
            Issue.record("expected an event"); return
        }
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-10-04T18:03:11Z"))
        #expect(abs(try #require(at).timeIntervalSince(expected) - 0.25) < 0.001)
    }

    @Test func everyPatternIsObservedNotGuessed() {
        for pattern in BluetoothLogParser.patterns {
            #expect(pattern.verification.isObserved, "\(pattern.id) has not been seen on a Mac")
        }
        #expect(Set(BluetoothLogParser.patterns.map(\.id)).count == BluetoothLogParser.patterns.count)
    }
}

@Suite struct BluetoothLogSourceTests {

    @Test func checksSessionPidsAgainstTheProcessTable() async {
        // 666 is sharingd; 398 now belongs to something else.
        let source = BluetoothLogSource(processName: { $0 == 666 ? "sharingd" : ($0 == 398 ? "someotherd" : nil) })
        await source.inject(lines: [Fixture.frameworkRequest, Fixture.xpcRequest], at: Date())
        let batch = await source.drain()
        #expect(batch.events.map(\.event) == [
            .request(.process(name: "sharingd", pid: 666), message: "kCBMsgIdDeviceFromIdentifierMsg"),
            .request(.process(name: "bluetoothd", pid: nil), message: "CBMsgIdScan"),
        ])
    }

    @Test func isRunningOnlyOnceLinesArriveAndCountsWhatItCouldNotRead() async {
        let source = BluetoothLogSource(processName: { _ in nil })
        let at = Date()
        await source.inject(lines: ["Filtering the log data using …", Fixture.command, Fixture.personal], at: at)
        let batch = await source.drain()
        #expect(batch.status == [.init(status: .running, at: at)])
        #expect(batch.linesRead == 3)
        #expect(batch.notJSON == 1)
        #expect(batch.events.count == 1)
        #expect(batch.uninterpreted.values.reduce(0, +) == 1)
        #expect(await source.drain().isEmpty)
    }
}
