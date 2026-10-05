import CoreWLAN
import Darwin
import Foundation
import PelicanKit

/// One interface's packet counters, as the kernel keeps them.
package struct InterfaceCounter: Sendable, Equatable, Codable {
    package var name: String
    package var packetsOut: UInt64
    package var packetsIn: UInt64
    package var isUp: Bool

    package init(name: String, packetsOut: UInt64, packetsIn: UInt64, isUp: Bool) {
        self.name = name
        self.packetsOut = packetsOut
        self.packetsIn = packetsIn
        self.isUp = isUp
    }

    /// Packets sent between two readings. The kernel's counters are 32-bit and wrap.
    package static func sent(from old: InterfaceCounter, to new: InterfaceCounter) -> UInt64 {
        if new.packetsOut >= old.packetsOut { return new.packetsOut - old.packetsOut }
        return new.packetsOut + (UInt64(UInt32.max) + 1 - old.packetsOut)
    }
}

/// What Pelican asks macOS about the radios. A protocol so the store can be tested against a
/// scripted Mac.
package protocol RadioSystem: Sendable {
    func posture() -> RadioPosture
    /// Packet counters for these interfaces, by name. Interfaces that do not exist are left out.
    func counters(named names: Set<String>) -> [String: InterfaceCounter]
    /// The drivers' counters on the radio chips' own transports.
    func transports() -> TransportSnapshot
}

package extension RadioSystem {
    /// The interfaces that share the Wi-Fi radio.
    func wifiCounters() -> [String: InterfaceCounter] { counters(named: LiveRadioSystem.wifiFamily()) }
}

/// The real Mac.
///
/// - Wi-Fi: CoreWLAN's power state for the Wi-Fi interface. Only power is read — never the
///   network name, which would need Location access.
/// - Lockdown Mode: the `LDMGlobalEnabled` preference. LIMIT: undocumented, and any process
///   running as the user can write it, so it is a label, not proof.
/// - Bluetooth: unknown. Pelican does not read Bluetooth's power switch: CoreBluetooth would
///   answer, but it would make Pelican ask for Bluetooth permission and become a client of the
///   daemon it is watching. What the Bluetooth chip's transport carries is counted instead, which
///   answers the question that matters whichever way the switch is set.
/// - Transports: the drivers' own counters, through IOReport.
package struct LiveRadioSystem: RadioSystem {

    private let reader: IOReportTransports

    package init(reader: IOReportTransports = IOReportTransports()) {
        self.reader = reader
    }

    package static let wifiBasis = "CoreWLAN power state"
    package static let lockdownBasis = "the LDMGlobalEnabled preference"
    package static let bluetoothBasis = "not read — Pelican counts what reaches the Bluetooth chip instead of asking for Bluetooth permission"
    package static let transportBasis = "the drivers' own counters, read through IOReport"

    package func transports() -> TransportSnapshot { reader.snapshot() }

    package func posture() -> RadioPosture {
        RadioPosture(wifi: Self.wifi(), bluetooth: .unknown, lockdown: Self.lockdown())
    }

    package static func wifi() -> Reported {
        // No Wi-Fi interface at all is as off as a radio gets.
        guard let interface = CWWiFiClient.shared().interface() else { return .off }
        return interface.powerOn() ? .on : .off
    }

    package static func wifiInterfaceName() -> String? {
        CWWiFiClient.shared().interface()?.interfaceName
    }

    package static func lockdown() -> Reported {
        let value = CFPreferencesCopyAppValue("LDMGlobalEnabled" as CFString, kCFPreferencesAnyApplication)
        guard let value else { return .off }  // never set: Lockdown Mode has not been turned on
        if let number = value as? NSNumber { return number.boolValue ? .on : .off }
        return .unknown
    }

    /// The Wi-Fi interface itself, plus the ones that ride on the same radio: AWDL (AirDrop,
    /// Sidecar), its low-latency companion, NAN and the access-point interface.
    package static func wifiFamily() -> Set<String> {
        [wifiInterfaceName() ?? "en0", "awdl0", "llw0", "nan0", "ap1"]
    }

    package func counters(named names: Set<String>) -> [String: InterfaceCounter] {
        Self.counters(named: names)
    }

    /// Per-interface packet counters from `getifaddrs`.
    package static func counters(named names: Set<String>) -> [String: InterfaceCounter] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var out: [String: InterfaceCounter] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let raw = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard names.contains(name) else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            out[name] = InterfaceCounter(
                name: name, packetsOut: UInt64(data.ifi_opackets), packetsIn: UInt64(data.ifi_ipackets),
                isUp: entry.pointee.ifa_flags & UInt32(IFF_UP) != 0)
        }
        return out
    }
}
