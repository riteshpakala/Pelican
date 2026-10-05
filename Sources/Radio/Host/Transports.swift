import Foundation
import IOKit
import PelicanKit

/// A part of the radios' plumbing inside the Mac whose traffic the kernel counts.
///
/// The Bluetooth chip talks to macOS over PCIe, through channels its driver names by protocol
/// (`ACIPCInterfaceProtocol` in the registry). Each channel is a queue pair, and the driver
/// counts every packet handed to the chip and every packet the chip hands back — below
/// bluetoothd and anything it chooses to log.
package enum TransportLink: String, Sendable, Codable, CaseIterable {
    /// Commands to the Bluetooth chip and events from it: scanning, advertising, connections.
    case hci
    /// Data to and from connected devices: GATT, L2CAP, A2DP audio.
    case acl
    /// Voice for calls.
    case sco
    /// LE Audio.
    case iso
    /// Time sync between the chip and the Mac.
    case tsi
    /// Interrupts the Bluetooth chip raised on its PCIe function: each is the chip telling the
    /// Mac it has something.
    case bluetoothInterrupts
    /// The Bluetooth radio asking for the antenna it shares with Wi-Fi, as the Wi-Fi driver counts
    /// it. Only counted while the Wi-Fi driver is running.
    case bluetoothAntenna
    /// The Wi-Fi chip's PCIe bus: doorbells the Mac rang to it, interrupts it raised.
    case wifiBus
    /// The Wi-Fi radio's own airtime, in microseconds.
    case wifiAirtime

    /// The Bluetooth chip's channels, named by their `ACIPCInterfaceProtocol`.
    package static let pipes: [TransportLink] = [.hci, .acl, .sco, .iso, .tsi]
    package static let bluetooth: [TransportLink] = pipes + [.bluetoothInterrupts, .bluetoothAntenna]
    package static let wifi: [TransportLink] = [.wifiBus, .wifiAirtime]

    /// Channels that carry payload toward the air rather than control or housekeeping.
    package var carriesData: Bool { self == .acl || self == .sco || self == .iso }

    package var label: String {
        switch self {
        case .hci: return "HCI"
        case .acl: return "ACL data"
        case .sco: return "SCO voice"
        case .iso: return "ISO audio"
        case .tsi: return "Time sync"
        case .bluetoothInterrupts: return "Interrupts"
        case .bluetoothAntenna: return "Antenna requests"
        case .wifiBus: return "Wi-Fi bus"
        case .wifiAirtime: return "Wi-Fi airtime"
        }
    }

    package var meaning: String {
        switch self {
        case .hci: return "commands to the chip (scanning, advertising, connecting) and events from it"
        case .acl: return "data for connected devices: GATT, L2CAP, audio streams"
        case .sco: return "voice during calls"
        case .iso: return "LE Audio"
        case .tsi: return "time synchronisation between the chip and the Mac"
        case .bluetoothInterrupts: return "the chip signalling the Mac that it has something"
        case .bluetoothAntenna: return "Bluetooth asking for the antenna it shares with Wi-Fi, counted by the Wi-Fi driver"
        case .wifiBus: return "doorbells the Mac rang to the Wi-Fi chip, and interrupts it raised"
        case .wifiAirtime: return "time the Wi-Fi radio spent transmitting and receiving"
        }
    }

    /// What `out` and `in` mean on this link. Out is always toward the radio and the air.
    package var outLabel: String? {
        switch self {
        case .hci: return "commands to chip"
        case .acl, .sco, .iso, .tsi: return "to chip"
        case .bluetoothInterrupts: return nil
        case .bluetoothAntenna: return "requests"
        case .wifiBus: return "doorbells"
        case .wifiAirtime: return "transmitting"
        }
    }

    package var inLabel: String? {
        switch self {
        case .hci: return "events from chip"
        case .acl, .sco, .iso, .tsi: return "from chip"
        case .bluetoothInterrupts: return "from chip"
        case .bluetoothAntenna: return nil
        case .wifiBus: return "interrupts"
        case .wifiAirtime: return "receiving"
        }
    }

    package var unit: String {
        switch self {
        case .hci, .acl, .sco, .iso, .tsi: return "packets"
        case .bluetoothInterrupts: return "interrupts"
        case .bluetoothAntenna: return "requests"
        case .wifiBus: return "events"
        case .wifiAirtime: return "µs"
        }
    }
}

/// Out is toward the radio and the air; in is from it.
package enum TransportDirection: String, Sendable, Codable {
    case out, `in`
}

/// "acl.out" — how movement is keyed in the day's record.
package func transportKey(_ link: TransportLink, _ direction: TransportDirection) -> String {
    "\(link.rawValue).\(direction.rawValue)"
}

/// One cumulative counter, as its driver keeps it.
package struct TransportCounter: Sendable, Equatable {
    /// Stable for as long as the driver object lives: its registry id and the channel's name.
    package var key: String
    package var link: TransportLink
    package var direction: TransportDirection
    /// For antenna requests broken down by cause: what Bluetooth wanted the air for.
    package var reason: String?
    package var value: Int64

    package init(key: String, link: TransportLink, direction: TransportDirection, reason: String? = nil, value: Int64) {
        self.key = key
        self.link = link
        self.direction = direction
        self.reason = reason
        self.value = value
    }
}

/// Every counter read at one moment.
package struct TransportSnapshot: Sendable, Equatable {
    package var counters: [TransportCounter]
    package var status: FlowSourceStatus

    package init(counters: [TransportCounter], status: FlowSourceStatus) {
        self.counters = counters
        self.status = status
    }

    package var links: Set<TransportLink> { Set(counters.map(\.link)) }
}

/// What moved between two readings.
package struct TransportMovement: Sendable, Equatable {
    /// By `transportKey(link, direction)`.
    package var counts: [String: Int] = [:]
    /// Antenna requests by cause.
    package var reasons: [String: Int] = [:]

    package init(counts: [String: Int] = [:], reasons: [String: Int] = [:]) {
        self.counts = counts
        self.reasons = reasons
    }

    package var isEmpty: Bool { counts.values.allSatisfy { $0 == 0 } }

    package func count(_ link: TransportLink, _ direction: TransportDirection) -> Int {
        counts[transportKey(link, direction)] ?? 0
    }

    /// Packets handed to the Bluetooth chip on the channels that carry payload.
    package var dataToBluetooth: Int { TransportLink.allCases.filter(\.carriesData).reduce(0) { $0 + count($1, .out) } }
}

/// Turns cumulative counters into movement between readings. Pure.
///
/// The first reading only sets the baseline: what moved before Pelican looked has no time and is
/// not counted. A counter that goes backwards (its driver restarted) is a new baseline, never a
/// negative count. A counter first seen later — a channel created when Bluetooth was switched on
/// — is counted from when it is first read.
package struct TransportMeter: Sendable {
    private var last: [String: Int64] = [:]

    package init() {}

    package mutating func read(_ snapshot: TransportSnapshot) -> TransportMovement {
        var movement = TransportMovement()
        var next: [String: Int64] = [:]
        for counter in snapshot.counters {
            next[counter.key] = counter.value
            guard let previous = last[counter.key], counter.value > previous else { continue }
            let moved = Int(clamping: counter.value - previous)
            if let reason = counter.reason {
                movement.reasons[reason, default: 0] += moved
            } else {
                movement.counts[transportKey(counter.link, counter.direction), default: 0] += moved
            }
        }
        last = next
        return movement
    }
}

/// Which driver counters Pelican reads, and what each one is. Pure: the names are the drivers'
/// own, checked on macOS 27.0 (M-series, Apple's Bluetooth/Wi-Fi combo chip).
package enum TransportCatalog {

    /// The driver classes whose counters are read, by the name IOReport gives them.
    package static let drivers: Set<String> = [
        "IOSkywalkKernelPipeBSDClient", "bluetooth-pcie", "IO80211ReporterProxy", "AppleBCMWLANBusInterfacePCIe",
    ]

    /// The IOReport groups those counters are in.
    package static let groups = [
        "TX Completion Queue", "RX Completion Queue", "Interrupt Statistics (by index)",
        "BT Coex", "WLAN Power", "AppleBCMWLANBusInterfacePCIe",
    ]

    /// `bluetoothProtocol` is the `ACIPCInterfaceProtocol` above a Skywalk pipe, when the pipe
    /// sits under the Bluetooth module; nil for every other pipe.
    package static func classify(driver: String, bluetoothProtocol: String?, group: String, subgroup: String,
                                 name rawName: String) -> (link: TransportLink, direction: TransportDirection, reason: String?)? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        switch driver {
        case "IOSkywalkKernelPipeBSDClient":
            guard let bluetoothProtocol, let link = TransportLink(rawValue: bluetoothProtocol),
                  TransportLink.pipes.contains(link), name == "Pkt Cnt" else { return nil }
            switch group {
            case "TX Completion Queue": return (link, .out, nil)
            case "RX Completion Queue": return (link, .in, nil)
            default: return nil
            }
        case "bluetooth-pcie":
            guard group == "Interrupt Statistics (by index)", name == "First Level Interrupt Handler Count" else { return nil }
            return (.bluetoothInterrupts, .in, nil)
        case "IO80211ReporterProxy":
            if group == "BT Coex", subgroup == "Counters", name == "Antenna Requests" { return (.bluetoothAntenna, .out, nil) }
            if group == "BT Coex", subgroup == "Antenna Request Reason" { return (.bluetoothAntenna, .out, name) }
            if group == "WLAN Power", subgroup == "Phy Activity" {
                if name == "Radio Tx Dur" { return (.wifiAirtime, .out, nil) }
                if name == "Radio Rx Dur" { return (.wifiAirtime, .in, nil) }
            }
            return nil
        case "AppleBCMWLANBusInterfacePCIe":
            guard subgroup == "Bus Events" else { return nil }
            if name == "h2d Doorbell Rings" { return (.wifiBus, .out, nil) }
            if name == "d2h interrupt Counter" { return (.wifiBus, .in, nil) }
            return nil
        default:
            return nil
        }
    }

    /// "IOSkywalkKernelPipeBSDClient <id 0x100001107>" → ("IOSkywalkKernelPipeBSDClient", 0x100001107)
    package static func split(driverName: String) -> (name: String, registryID: UInt64?) {
        guard let open = driverName.range(of: " <id 0x") else { return (driverName, nil) }
        let digits = driverName[open.upperBound...].prefix { $0.isHexDigit }
        return (String(driverName[..<open.lowerBound]), UInt64(digits, radix: 16))
    }
}

/// The real Mac: driver counters read through libIOReport, the interface `powermetrics` uses.
/// Needs no root and no permission; it reads what the drivers already publish.
///
/// LIMIT: libIOReport is private and undocumented, and these counter names are the drivers' own.
/// If a macOS update renames them, the links are reported missing rather than silently quiet.
/// Counts are packets, not bytes: the drivers do not publish byte counts.
package final class IOReportTransports: @unchecked Sendable {

    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                                                           UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelFormat = @convention(c) (CFDictionary) -> Int32
    private typealias SimpleValue = @convention(c) (CFDictionary, Int32) -> Int64

    private struct Functions {
        let copyChannelsInGroup: CopyChannelsInGroup
        let mergeChannels: MergeChannels
        let createSubscription: CreateSubscription
        let createSamples: CreateSamples
        let driverName: ChannelString
        let group: ChannelString
        let subgroup: ChannelString
        let channelName: ChannelString
        let format: ChannelFormat
        let simpleValue: SimpleValue
    }

    private struct Role {
        let link: TransportLink
        let direction: TransportDirection
        let reason: String?
    }

    /// How often the set of channels is looked up again, to find channels created since (a
    /// Bluetooth pipe made when Bluetooth is switched on).
    package static let refreshInterval: TimeInterval = 15

    private let lock = NSLock()
    private let functions: Functions?
    private let loadError: String?
    private var subscription: OpaquePointer?          // lock-confined
    private var subscribed: CFMutableDictionary?      // lock-confined
    private var roles: [String: Role] = [:]           // lock-confined
    private var subscribedAt: Date?                   // lock-confined
    private var protocols: [UInt64: String?] = [:]    // lock-confined

    package init() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            functions = nil
            loadError = "libIOReport could not be loaded"
            return
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copy = symbol("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let merge = symbol("IOReportMergeChannels", MergeChannels.self),
              let subscribe = symbol("IOReportCreateSubscription", CreateSubscription.self),
              let samples = symbol("IOReportCreateSamples", CreateSamples.self),
              let driver = symbol("IOReportChannelGetDriverName", ChannelString.self),
              let group = symbol("IOReportChannelGetGroup", ChannelString.self),
              let subgroup = symbol("IOReportChannelGetSubGroup", ChannelString.self),
              let name = symbol("IOReportChannelGetChannelName", ChannelString.self),
              let format = symbol("IOReportChannelGetFormat", ChannelFormat.self),
              let value = symbol("IOReportSimpleGetIntegerValue", SimpleValue.self)
        else {
            functions = nil
            loadError = "libIOReport is missing a function Pelican uses"
            return
        }
        functions = Functions(copyChannelsInGroup: copy, mergeChannels: merge, createSubscription: subscribe,
                              createSamples: samples, driverName: driver, group: group, subgroup: subgroup,
                              channelName: name, format: format, simpleValue: value)
        loadError = nil
    }

    deinit {
        if let subscription { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(subscription)).release() }
    }

    package func snapshot(now: Date = Date()) -> TransportSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let functions else { return TransportSnapshot(counters: [], status: .unavailable(loadError ?? "unavailable")) }
        if subscription == nil || subscribedAt.map({ now.timeIntervalSince($0) >= Self.refreshInterval }) ?? true {
            subscribe(functions, now: now)
        }
        guard let subscription, let subscribed else {
            return TransportSnapshot(counters: [], status: .unavailable("the drivers publish none of the counters Pelican reads"))
        }
        guard let sample = functions.createSamples(subscription, subscribed, nil)?.takeRetainedValue() else {
            return TransportSnapshot(counters: [], status: .unavailable("the drivers' counters could not be sampled"))
        }
        var counters: [TransportCounter] = []
        forEachChannel(in: sample) { channel in
            guard functions.format(channel) == 1 else { return }  // simple integer counters only
            let key = self.key(functions, channel)
            guard let role = roles[key] else { return }
            counters.append(TransportCounter(key: key, link: role.link, direction: role.direction, reason: role.reason,
                                             value: functions.simpleValue(channel, 0)))
        }
        let bluetooth = counters.contains { TransportLink.pipes.contains($0.link) }
        return TransportSnapshot(counters: counters,
                                 status: bluetooth ? .running : .unavailable("no Bluetooth transport counters found"))
    }

    // MARK: - Subscribing

    private func subscribe(_ functions: Functions, now: Date) {
        if let subscription { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(subscription)).release() }
        subscription = nil
        subscribed = nil
        subscribedAt = now

        // Gather the groups, then keep only the channels the catalog names.
        var gathered: CFMutableDictionary?
        for group in TransportCatalog.groups {
            guard let channels = functions.copyChannelsInGroup(group as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let gathered { functions.mergeChannels(gathered, channels, nil) } else { gathered = channels }
        }
        guard let gathered else { return }

        // Toll-free bridged, so the array holds the original channel objects, not copies.
        let wanted = NSMutableArray()
        var nextRoles: [String: Role] = [:]
        forEachChannel(in: gathered) { channel in
            let driverName = string(functions.driverName(channel))
            let (driver, registryID) = TransportCatalog.split(driverName: driverName)
            guard TransportCatalog.drivers.contains(driver) else { return }
            let bluetoothProtocol = driver == "IOSkywalkKernelPipeBSDClient" ? registryID.flatMap(bluetoothProtocol) : nil
            guard let role = TransportCatalog.classify(
                driver: driver, bluetoothProtocol: bluetoothProtocol,
                group: string(functions.group(channel)), subgroup: string(functions.subgroup(channel)),
                name: string(functions.channelName(channel)))
            else { return }
            nextRoles[key(functions, channel)] = Role(link: role.link, direction: role.direction, reason: role.reason)
            wanted.add(channel)
        }
        roles = nextRoles
        guard wanted.count > 0 else { return }

        let desired = NSMutableDictionary()
        desired["IOReportChannels"] = wanted
        var out: Unmanaged<CFMutableDictionary>?
        guard let created = functions.createSubscription(nil, desired as CFMutableDictionary, &out, 0, nil), let out
        else { return }
        subscription = created
        subscribed = out.takeRetainedValue()
    }

    /// The `ACIPCInterfaceProtocol` above a Skywalk pipe ("hci", "acl", …), if the pipe belongs
    /// to the Bluetooth module. Remembered per registry id, which never changes for an object.
    private func bluetoothProtocol(registryID: UInt64) -> String? {
        if let known = protocols[registryID] { return known }
        let found = Self.lookUpProtocol(registryID: registryID)
        if protocols.count > 256 { protocols.removeAll() }
        protocols[registryID] = found
        return found
    }

    private static func lookUpProtocol(registryID: UInt64) -> String? {
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard entry != 0 else { return nil }
        var found: String?
        var underBluetooth = false
        for _ in 0..<8 {
            if found == nil,
               let value = IORegistryEntryCreateCFProperty(entry, "ACIPCInterfaceProtocol" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                found = value
            }
            if let className = IOObjectCopyClass(entry)?.takeRetainedValue() as String?, className == "AppleBluetoothModule" {
                underBluetooth = true
                break
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(entry)
            entry = parent
        }
        IOObjectRelease(entry)
        return underBluetooth ? found : nil
    }

    // MARK: - CF plumbing

    private func key(_ functions: Functions, _ channel: CFDictionary) -> String {
        [string(functions.driverName(channel)), string(functions.group(channel)),
         string(functions.subgroup(channel)), string(functions.channelName(channel))].joined(separator: "|")
    }

    /// IOReport's accessors cache into the channel dictionaries, so they must be handed the
    /// original CF objects, never Swift-bridged copies.
    private func forEachChannel(in report: CFDictionary, _ body: (CFDictionary) -> Void) {
        guard let raw = CFDictionaryGetValue(report, Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque())
        else { return }
        let channels = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        for index in 0..<CFArrayGetCount(channels) {
            guard let pointer = CFArrayGetValueAtIndex(channels, index) else { continue }
            body(Unmanaged<CFDictionary>.fromOpaque(pointer).takeUnretainedValue())
        }
    }
}

private func string(_ value: Unmanaged<CFString>?) -> String {
    (value?.takeUnretainedValue() as String?) ?? ""
}
