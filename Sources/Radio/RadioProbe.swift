import Foundation
import PelicanKit

/// `Pelican --radio-probe [seconds]`
///
/// Prints what Pelican can see of the radios on this Mac: the posture as macOS reports it, the
/// transports the drivers count traffic on, a line a second of what moved on each, and what
/// bluetoothd logged — interpreted, and counted by format when Pelican cannot interpret it.
///
/// Nothing a log message says is printed — they carry device names and addresses — only format
/// strings, process names, counts and Pelican's own reading.
package enum RadioProbe {

    package static func run(seconds: Double) async {
        print("Pelican radio probe · \(BuildInfo.current.line)")
        print(String(repeating: "─", count: 78))

        let system = LiveRadioSystem()
        var posture = system.posture()
        printPosture(posture)
        let startCounters = system.wifiCounters()

        var meter = TransportMeter()
        let first = system.transports()
        _ = meter.read(first)
        printTransports(first)

        print("\nWATCHING for \(Int(seconds))s — what moved each second (↑ toward the radio, ↓ from it)")
        let source = BluetoothLogSource(restart: nil)
        await source.start()
        var total = RadioBatch()
        var moved = TransportMovement()
        var statuses: [String] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            let now = Date()
            let second = meter.read(system.transports())
            for (key, count) in second.counts { moved.counts[key, default: 0] += count }
            for (reason, count) in second.reasons { moved.reasons[reason, default: 0] += count }
            print("  \(stamp(now))  \(line(second))")

            let batch = await source.drain()
            merge(batch, into: &total)
            for change in batch.status { statuses.append("\(stamp(change.at)) \(change.status.description)") }
            let nextPosture = system.posture()
            if nextPosture != posture {
                print("  \(stamp(now))  posture: \(posture.summary) → \(nextPosture.summary)")
                posture = nextPosture
            }
        }
        source.stopNow()
        await source.stop()
        merge(await source.drain(), into: &total)

        printMovement(moved, seconds: seconds)
        report(total, statuses: statuses)
        print("\nWI-FI INTERFACES — packets sent during the run")
        for (name, counter) in system.wifiCounters().sorted(by: { $0.key < $1.key }) {
            let sent = startCounters[name].map { InterfaceCounter.sent(from: $0, to: counter) } ?? 0
            print("  \(name.padding(toLength: 7, withPad: " ", startingAt: 0)) +\(sent)\(counter.isUp ? "" : "  (down)")")
        }
        print("\nLIMITS")
        print("  The transport counts are the drivers' own: below bluetoothd, but still the Mac's software")
        print("  counting itself. Anything the radio chip's firmware does on its own — without the Mac")
        print("  handing it a packet — does not pass through these channels and is not counted. BLE")
        print("  advertising is the main case: one HCI command starts it (counted), then the chip")
        print("  advertises by itself. While Wi-Fi is on, antenna requests may still show it.")
    }

    // MARK: - Transports

    private static func printTransports(_ snapshot: TransportSnapshot) {
        print("\nTRANSPORTS — \(LiveRadioSystem.transportBasis)")
        if case .unavailable(let reason) = snapshot.status { print("  Bluetooth transport unavailable: \(reason)") }
        for link in TransportLink.allCases {
            let counters = snapshot.counters.filter { $0.link == link && $0.reason == nil }
            let found = counters.isEmpty ? "not found" : "\(counters.count) counter\(counters.count == 1 ? "" : "s")"
            print("  \(link.label.padding(toLength: 17, withPad: " ", startingAt: 0)) \(found.padding(toLength: 11, withPad: " ", startingAt: 0)) \(link.meaning)")
        }
    }

    /// "hci ↑2 ↓5  acl ↑35 ↓2  irq ↓43 …" — only what moved.
    private static func line(_ movement: TransportMovement) -> String {
        var parts: [String] = []
        for link in TransportLink.allCases {
            let out = movement.count(link, .out)
            let into = movement.count(link, .in)
            guard out + into > 0 else { continue }
            var part = short(link)
            if out > 0 { part += " ↑\(amount(out, link))" }
            if into > 0 { part += " ↓\(amount(into, link))" }
            parts.append(part)
        }
        return parts.isEmpty ? "nothing moved" : parts.joined(separator: "  ")
    }

    private static func printMovement(_ moved: TransportMovement, seconds: Double) {
        print("\nMOVED DURING THE RUN")
        for link in TransportLink.allCases {
            let out = moved.count(link, .out)
            let into = moved.count(link, .in)
            var parts: [String] = []
            if let label = link.outLabel { parts.append("\(label) \(amount(out, link))") }
            if let label = link.inLabel { parts.append("\(label) \(amount(into, link))") }
            print("  \(link.label.padding(toLength: 17, withPad: " ", startingAt: 0)) \(parts.joined(separator: ", "))")
        }
        if !moved.reasons.isEmpty {
            let reasons = moved.reasons.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("  antenna requested for: \(reasons)")
        }
    }

    private static func short(_ link: TransportLink) -> String {
        switch link {
        case .hci, .acl, .sco, .iso, .tsi: return link.rawValue
        case .bluetoothInterrupts: return "irq"
        case .bluetoothAntenna: return "antenna"
        case .wifiBus: return "wifi-bus"
        case .wifiAirtime: return "wifi-air"
        }
    }

    private static func amount(_ value: Int, _ link: TransportLink) -> String {
        guard link == .wifiAirtime else { return "\(value)" }
        return value >= 1_000 ? String(format: "%.1fms", Double(value) / 1_000) : "\(value)µs"
    }

    // MARK: - Posture and the log

    private static func printPosture(_ posture: RadioPosture) {
        print("\nPOSTURE — as macOS reports it")
        let wifiName = LiveRadioSystem.wifiInterfaceName().map { " (\($0))" } ?? ""
        print("  Wi-Fi       \(posture.wifi.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(LiveRadioSystem.wifiBasis)\(wifiName)")
        print("  Bluetooth   \(posture.bluetooth.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(LiveRadioSystem.bluetoothBasis)")
        print("  Lockdown    \(posture.lockdown.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(LiveRadioSystem.lockdownBasis)")
        print("  locked down \(posture.isLockedDown ? "yes" : "no") (Wi-Fi off and Lockdown Mode on)")
    }

    private static func merge(_ batch: RadioBatch, into total: inout RadioBatch) {
        total.events += batch.events
        total.linesRead += batch.linesRead
        total.notJSON += batch.notJSON
        total.oversized += batch.oversized
        total.status += batch.status
        for (key, count) in batch.uninterpreted { total.uninterpreted[key, default: 0] += count }
    }

    private static func report(_ total: RadioBatch, statuses: [String]) {
        print("\nBLUETOOTHD'S LOG — \(BluetoothLogSource.command.display)")
        if statuses.isEmpty { print("  no status reported — did `log` start?") }
        for status in statuses { print("  \(status)") }
        let readable = total.linesRead - total.notJSON
        let share = readable == 0 ? 0 : Int((Double(total.events.count) / Double(readable) * 100).rounded())
        print("  \(readable) log entries: \(total.events.count) interpreted (\(share)%), \(total.notJSON) lines not JSON, \(total.oversized) too long")

        var subjects: [String: (reports: Int, packets: Int, why: String)] = [:]
        for timed in total.events {
            guard let sent = timed.event.transmission else { continue }
            var entry = subjects[sent.subject] ?? (0, 0, sent.why)
            entry.reports += 1
            entry.packets += sent.packets
            subjects[sent.subject] = entry
        }
        print("\n  TRANSMISSIONS bluetoothd reported")
        if subjects.isEmpty { print("    none") }
        for (subject, entry) in subjects.sorted(by: { $0.value.reports > $1.value.reports }) {
            let packets = entry.packets > 0 ? ", \(entry.packets) packets" : ""
            print("    \(subject): \(entry.reports) report\(entry.reports == 1 ? "" : "s")\(packets) — \(entry.why)")
        }

        var clients: [String: (requests: Int, scans: Int, active: Int, indications: Int)] = [:]
        for timed in total.events {
            switch timed.event {
            case .request(let client, _): clients[client.label, default: (0, 0, 0, 0)].requests += 1
            case .scanStopRequested(let client): clients[client.label, default: (0, 0, 0, 0)].requests += 1
            case .scanRequested(let client, let active):
                clients[client.label, default: (0, 0, 0, 0)].scans += 1
                if active == true { clients[client.label, default: (0, 0, 0, 0)].active += 1 }
            case .indication(let client): clients[client.label, default: (0, 0, 0, 0)].indications += 1
            case .scanAgents(let agents): for agent in agents { _ = clients[agent.label, default: (0, 0, 0, 0)] }
            default: break
            }
        }
        print("\n  CLIENTS — who asked bluetoothd for something")
        if clients.isEmpty { print("    none") }
        for (label, entry) in clients.sorted(by: { $0.value.requests + $0.value.scans > $1.value.requests + $1.value.scans }) {
            print("    \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) requests \(entry.requests)  scans \(entry.scans) (active \(entry.active))  indications \(entry.indications)")
        }

        print("\n  NOT INTERPRETED — by format string, most frequent first")
        if total.uninterpreted.isEmpty { print("    none") }
        for (key, count) in total.uninterpreted.sorted(by: { $0.value > $1.value }).prefix(15) {
            print("    \(String(count).padding(toLength: 6, withPad: " ", startingAt: 0)) \(key)")
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
    }
}
