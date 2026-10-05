import Foundation
import PelicanKit

/// What macOS reports a radio or a setting to be. `unknown` is never treated as off.
package enum Reported: String, Sendable, Codable, Hashable {
    case on, off, unknown
}

/// The three things the question turns on — Wi-Fi, Bluetooth and Lockdown Mode — as macOS
/// reports them at one moment. These are the system's own answers, not measurements.
package struct RadioPosture: Sendable, Codable, Hashable {
    package var wifi: Reported
    package var bluetooth: Reported
    package var lockdown: Reported

    package init(wifi: Reported, bluetooth: Reported, lockdown: Reported) {
        self.wifi = wifi
        self.bluetooth = bluetooth
        self.lockdown = lockdown
    }

    package static let unknown = RadioPosture(wifi: .unknown, bluetooth: .unknown, lockdown: .unknown)

    /// Wi-Fi off and Lockdown Mode on: the posture in which every transmission macOS reports
    /// is itemised. Bluetooth may still be on.
    package var isLockedDown: Bool { wifi == .off && lockdown == .on }

    /// Every radio Pelican can ask about reported off. Bluetooth must be known to be off, never
    /// assumed.
    package var radiosOff: Bool { wifi == .off && bluetooth == .off }

    package var summary: String {
        "Wi-Fi \(wifi.rawValue), Bluetooth \(bluetooth.rawValue), Lockdown Mode \(lockdown.rawValue)"
    }
}

/// How Pelican knows something about the radios. Kept apart from Leak Guard's Seen and Likely,
/// which say whether Pelican read a message's contents; nothing here is read from contents.
package enum RadioEvidence: Sendable, Codable, Hashable {
    /// What a system service said about itself — a log line, a setting.
    case reported(source: String)
    /// What a kernel driver counted on the hardware's own transport — below any daemon, though
    /// still counted by the Mac's own software.
    case counted(source: String)
    /// A conclusion from something Pelican can name, not a reading.
    case inferred(basis: String)

    package var label: String {
        switch self {
        case .reported(let source): return "reported by \(source)"
        case .counted(let source): return "counted by \(source)"
        case .inferred(let basis): return "inferred — \(basis)"
        }
    }
}

/// Who asked bluetoothd for something, as the daemon's own log names it.
package enum RadioClient: Sendable, Codable, Hashable {
    /// A process. The pid is nil when the name came from a session string and the pid it carried
    /// no longer belonged to a process of that name.
    case process(name: String, pid: Int32?)
    /// A session name that names no process, with any pointer-like numbers masked.
    case session(String)

    package var key: String {
        switch self {
        case .process(let name, _): return "process:\(name)"
        case .session(let name): return "session:\(name)"
        }
    }

    package var label: String {
        switch self {
        case .process(let name, let pid): return pid.map { "\(name) (pid \($0))" } ?? name
        case .session(let name): return "session \(name)"
        }
    }

    package var name: String {
        switch self {
        case .process(let name, _): return name
        case .session(let name): return name
        }
    }
}

/// A Bluetooth link, as bluetoothd's periodic reports name it.
package enum LinkKind: String, Sendable, Codable, Hashable {
    case le, classic, audio

    package var label: String {
        switch self {
        case .le: return "LE link"
        case .classic: return "Classic link"
        case .audio: return "audio link"
        }
    }
}

/// One thing bluetoothd said, reduced to what Pelican keeps. Names, addresses and payloads in
/// the log line never make it into one of these.
package enum BluetoothEvent: Sendable, Equatable {
    /// A client asked for a scan. Active scans transmit scan requests; passive scans only
    /// listen; nil when the line does not say.
    case scanRequested(RadioClient, active: Bool?)
    case scanStopRequested(RadioClient)
    /// The controller started scanning.
    case scanStarted(active: Bool)
    /// A client sent bluetoothd a request.
    case request(RadioClient, message: String)
    /// The clients the controller is scanning on behalf of.
    case scanAgents([RadioClient])
    /// A connected device's notification passed to a client — received, not sent.
    case indication(RadioClient)
    /// One periodic report of a link's counters, under the names bluetoothd prints. Apple does
    /// not document what `tx [S=:F=]` counts, so it is kept as printed.
    case linkReport(LinkKind, handle: String, txSuccess: Int, txFailed: Int, rxSuccess: Int, rxFailed: Int)
    /// Packets sent to a connected audio device in one report.
    case audioReport(txPackets: Int, retransmitted: Int)
    /// bluetoothd's coexistence manager registering an LE connection. It repeats every few
    /// seconds for a connection that is already up, so it does not mark a new link.
    case connectionAdded(LinkKind)
    /// A message a connected accessory sent the Mac — received, not sent.
    case accessoryMessage
    /// A line that repeats what another component already logged for the same thing.
    case echo
    /// A command the Mac sent to its own Bluetooth controller (inside the Mac, not over the air).
    case controllerCommand(String)
    /// bluetoothd's own view of Wi-Fi, from its coexistence report.
    case wlanStatus(Reported)
    /// Advertisements heard from nearby devices — received, never sent.
    case devicesHeard(Int)

    /// What a transmission is attributed to, and why this event means the radio sent something.
    package struct Transmission: Sendable, Equatable {
        package var subject: String
        package var packets: Int
        package var why: String
    }

    /// Whether this report means the Mac's Bluetooth radio transmitted, according to macOS.
    package var transmission: Transmission? {
        switch self {
        case .scanRequested(let client, let active):
            guard active == true else { return nil }
            return Transmission(subject: client.label, packets: 0,
                                why: "asked for an active scan, which sends scan requests")
        case .scanStarted(let active):
            guard active else { return nil }
            return Transmission(subject: "Bluetooth controller", packets: 0,
                                why: "started an active scan, which sends scan requests")
        case .linkReport(let kind, let handle, let txSuccess, let txFailed, _, _):
            guard txSuccess + txFailed > 0 else { return nil }
            return Transmission(subject: "\(kind.label) \(handle)", packets: txSuccess + txFailed,
                                why: "its report counted transmissions")
        case .audioReport(let txPackets, _):
            guard txPackets > 0 else { return nil }
            return Transmission(subject: LinkKind.audio.label, packets: txPackets,
                                why: "sent audio packets to a connected device")
        default:
            // An open link also transmits to keep itself alive; macOS logs no count of that, so
            // it is not counted here.
            return nil
        }
    }
}

/// A finding about the radios. Each says how Pelican knows (`evidence`), and one finding stands
/// for every repetition of the same thing in the same posture.
package struct RadioFinding: Sendable, Codable, Hashable, Identifiable {
    package enum Kind: String, Sendable, Codable, CaseIterable {
        /// macOS reported a transmission while Wi-Fi was off and Lockdown Mode on.
        case transmittedWhileLockedDown
        /// macOS reported a transmission while it also reported Bluetooth off.
        case transmittedWhileBluetoothOff
        /// The Mac kept commanding its Bluetooth controller while reporting Bluetooth off.
        case commandsWhileBluetoothOff
        /// An interface counted packets sent while Wi-Fi was reported off.
        case packetsWhileWiFiOff
        /// Two of macOS's own reports disagree about Wi-Fi.
        case reportsDisagree
        /// Packets went into the Bluetooth chip's transport while Wi-Fi was off and Lockdown
        /// Mode on.
        case dataIntoBluetoothWhileLockedDown
        /// The Wi-Fi radio counted transmit airtime while Wi-Fi was reported off.
        case wifiTransmittedWhileOff
        /// The Wi-Fi chip's bus kept moving while Wi-Fi was reported off.
        case wifiChipBusyWhileOff
        /// Something Pelican was asked to switch off is on again.
        case turnedBackOn
        /// An interface the person asked to be off counted packets anyway.
        case movedWhileSwitchedOff

        /// A contradiction is two things that cannot both be true; the rest are worth a look.
        package var isContradiction: Bool {
            switch self {
            case .transmittedWhileBluetoothOff, .packetsWhileWiFiOff, .wifiTransmittedWhileOff,
                 .turnedBackOn, .movedWhileSwitchedOff: return true
            case .transmittedWhileLockedDown, .commandsWhileBluetoothOff, .reportsDisagree,
                 .dataIntoBluetoothWhileLockedDown, .wifiChipBusyWhileOff: return false
            }
        }

        package var title: String {
            switch self {
            case .transmittedWhileLockedDown: return "Transmitted while locked down"
            case .transmittedWhileBluetoothOff: return "Transmitted with Bluetooth off"
            case .commandsWhileBluetoothOff: return "Controller busy with Bluetooth off"
            case .packetsWhileWiFiOff: return "Packets sent with Wi-Fi off"
            case .reportsDisagree: return "macOS's reports disagree"
            case .dataIntoBluetoothWhileLockedDown: return "Into the Bluetooth chip while locked down"
            case .wifiTransmittedWhileOff: return "Wi-Fi radio transmitted while off"
            case .wifiChipBusyWhileOff: return "Wi-Fi chip busy while off"
            case .turnedBackOn: return "Turned back on"
            case .movedWhileSwitchedOff: return "Moved after being switched off"
            }
        }

        /// Whether this is a state that holds rather than a thing that happens. A state is
        /// recorded once and its end extended for as long as it lasts: Wi-Fi being on again is
        /// one fact confirmed every second, not one event per second.
        package var isState: Bool { self == .turnedBackOn }

        /// What a finding's count counts.
        package var unit: String {
            switch self {
            case .packetsWhileWiFiOff, .dataIntoBluetoothWhileLockedDown, .movedWhileSwitchedOff: return "packet"
            case .wifiTransmittedWhileOff: return "µs of airtime"
            case .wifiChipBusyWhileOff: return "bus event"
            default: return "time"
            }
        }
    }

    package var id: String
    package var kind: Kind
    package var subject: String
    package var evidence: RadioEvidence
    package var detail: String
    package var count: Int
    package var firstSeen: Date
    package var lastSeen: Date

    package init(id: String, kind: Kind, subject: String, evidence: RadioEvidence, detail: String,
                 count: Int = 1, firstSeen: Date, lastSeen: Date) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.evidence = evidence
        self.detail = detail
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// What the person asked to be switched off, and when. Kept so Pelican can go on checking that
/// it stayed off, which is the part that is worth anything: the switch is a request to macOS,
/// the counters are the check.
package struct QuietRequest: Sendable, Codable, Hashable {
    package var since: Date
    /// Wi-Fi's radio was switched off.
    package var wifi: Bool
    /// The wired services Pelican disabled, by name. Only these are enabled again on restore,
    /// so a service that was already off stays off.
    package var services: [String]
    /// The person said they had switched Bluetooth off themselves. Pelican does not switch
    /// Bluetooth: that needs Bluetooth permission, and it would drop your keyboard and mouse.
    package var bluetooth: Bool

    package init(since: Date, wifi: Bool, services: [String], bluetooth: Bool) {
        self.since = since
        self.wifi = wifi
        self.services = services
        self.bluetooth = bluetooth
    }

    package var isEmpty: Bool { !wifi && services.isEmpty && !bluetooth }

    package var summary: String {
        var parts: [String] = []
        if wifi { parts.append("Wi-Fi") }
        if !services.isEmpty { parts.append("\(services.count) wired service\(services.count == 1 ? "" : "s")") }
        if bluetooth { parts.append("Bluetooth (by you)") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}

/// Whether what was switched off has stayed off.
package enum QuietStanding: Sendable, Equatable {
    /// Nothing was asked to be off.
    case notAsked
    /// Still off, and nothing has moved since.
    case holding(since: Date)
    /// Something came back on, or moved anyway.
    case broken(Int)
}

/// Minutes since 1970 in UTC, so a minute means the same thing across a time-zone change.
package enum EpochMinute {
    package static func of(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 60).rounded(.down)) }
    package static func start(_ minute: Int) -> Date { Date(timeIntervalSince1970: Double(minute) * 60) }
}
