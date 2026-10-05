import Foundation
import PelicanKit

/// The fields of one `log stream --style ndjson` entry that Pelican reads.
package struct LogEntry: Sendable, Decodable, Equatable {
    package var timestamp: String?
    package var messageType: String?
    package var subsystem: String?
    package var category: String?
    package var formatString: String?
    package var eventMessage: String?
    package var processImagePath: String?
    package var processID: Int32?

    package var process: String {
        processImagePath.map { ($0 as NSString).lastPathComponent } ?? "?"
    }
}

/// One line of the log, interpreted.
package enum ParsedLine: Sendable, Equatable {
    case event(BluetoothEvent, at: Date?, pattern: String)
    /// A log entry no pattern matches, keyed by process, category and format string — static
    /// text written by Apple's engineers, never the message itself, which can carry device names
    /// and addresses.
    case uninterpreted(key: String)
    /// `log` prints a banner and a trailer that are not JSON.
    case notJSON
}

/// A line bluetoothd writes that Pelican knows how to read.
package struct LogPattern: Sendable {
    package let id: String
    package let category: String
    /// The start of the entry's format string.
    package let format: String
    /// For entries whose format string is only `%{public}s`, the start of the message.
    package let message: String?
    /// When and where this line was seen, so a reader can check it against their own Mac.
    package let verification: Verification
    package let meaning: String
    let read: @Sendable (_ message: String) -> BluetoothEvent?
}

/// Turns bluetoothd's log into `BluetoothEvent`s. Pure: every pattern is tested against lines of
/// the shape macOS writes, with names and addresses made up.
///
/// LIMIT: Apple does not document these lines and can change them in any update. Lines no pattern
/// matches are counted by format string and shown, so a change is visible rather than silent.
package enum BluetoothLogParser {

    /// What the patterns below were checked against.
    private static let seen = Verification.observed(on: "2026-10-04", version: "macOS 27.0")

    // MARK: - Reading a line

    package static func parse(_ line: String) -> ParsedLine {
        guard line.first == "{", let data = line.data(using: .utf8),
              let entry = try? JSONDecoder().decode(LogEntry.self, from: data),
              entry.eventMessage != nil
        else { return .notJSON }
        return interpret(entry)
    }

    package static func interpret(_ entry: LogEntry) -> ParsedLine {
        let category = entry.category ?? ""
        let format = entry.formatString ?? ""
        let message = entry.eventMessage ?? ""
        for pattern in patterns where pattern.category == category && format.hasPrefix(pattern.format) {
            if let start = pattern.message, !message.hasPrefix(start) { continue }
            if let event = pattern.read(message) {
                return .event(event, at: entry.timestamp.flatMap(date), pattern: pattern.id)
            }
        }
        return .uninterpreted(key: uninterpretedKey(entry))
    }

    package static func uninterpretedKey(_ entry: LogEntry) -> String {
        let format = (entry.formatString ?? "").prefix(160)
        return "\(entry.process) \(entry.category ?? "-"): \(format)"
    }

    // MARK: - The patterns

    package static let patterns: [LogPattern] = [
        LogPattern(
            id: "scan-for-process", category: "WirelessProximity",
            format: "Start scanning for process %{public}@ (%d) with ", message: nil,
            verification: seen,
            meaning: "a process asked for a proximity scan; `active: 1` means the scan transmits",
            read: { message in
                guard let parts = groups(scanForProcess, message), let pid = Int32(parts[1]) else { return nil }
                let active = groups(activeFlag, message).map { $0[0] != "0" }
                return .scanRequested(.process(name: parts[0], pid: pid), active: active)
            }),
        LogPattern(
            id: "start-scan-request", category: "Server.LE.Scan",
            format: "%{public}s", message: "Received 'start ",
            verification: seen,
            meaning: "a session asked the controller to start scanning",
            read: { message in
                guard let session = groups(fromSession, message)?[0] else { return nil }
                return .scanRequested(client(session: session), active: nil)
            }),
        LogPattern(
            id: "stop-scan-request", category: "Server.LE.Scan",
            format: "Received 'stop scan' request from session ", message: nil,
            verification: seen,
            meaning: "a session asked the controller to stop scanning",
            read: { message in
                guard let session = groups(fromSession, message)?[0] else { return nil }
                return .scanStopRequested(client(session: session))
            }),
        LogPattern(
            id: "starting-scan", category: "Server.LE.Scan",
            format: "%{public}sStarting %{public}s scan", message: nil,
            verification: seen,
            meaning: "the controller started a passive (listening) or active (transmitting) scan",
            read: { message in
                guard let kind = groups(startingScan, message)?[0] else { return nil }
                return .scanStarted(active: kind == "active")
            }),
        LogPattern(
            id: "scan-agents", category: "Server.LE.Scan",
            format: "ScanParams: %{public}@", message: nil,
            verification: seen,
            meaning: "the sessions the controller is scanning for",
            read: { message in
                let sessions = allGroups(bracketed, message)
                return sessions.isEmpty ? nil : .scanAgents(sessions.map(client(session:)))
            }),
        LogPattern(
            id: "xpc-request", category: "Server.XPC",
            format: "Received XPC message \"%{public}s\" from session \"%{public}s\"", message: nil,
            verification: seen,
            meaning: "a process sent bluetoothd a request",
            read: { request($0) }),
        LogPattern(
            id: "framework-request", category: "Server.XPC",
            format: "Received MBFramework XPC message \"%{public}s\" from session \"%{public}s\"", message: nil,
            verification: seen,
            meaning: "a process sent bluetoothd a request through the Bluetooth framework",
            read: { request($0) }),
        LogPattern(
            id: "gatt-indication", category: "Server.App",
            format: "Dispatching GATT indication for device ", message: nil,
            verification: seen,
            meaning: "a connected device notified a process — received, not sent",
            read: { message in
                guard let session = groups(toSession, message)?[0] else { return nil }
                return .indication(client(session: session))
            }),
        LogPattern(
            id: "le-link-report", category: "Server.Core",
            format: "Le [0x%x]: ", message: nil,
            verification: seen,
            meaning: "an LE link's counters, reported about once a second",
            read: { link(.le, $0) }),
        LogPattern(
            id: "classic-link-report", category: "Server.Core",
            format: "Classic [0x%x]: ", message: nil,
            verification: seen,
            meaning: "a Classic link's counters, reported about once a second",
            read: { link(.classic, $0) }),
        LogPattern(
            id: "audio-report", category: "Server.Audio",
            format: "BeamformingReport: ", message: nil,
            verification: seen,
            meaning: "audio packets sent to a connected device in the last report",
            read: { message in
                guard let parts = groups(beamforming, message),
                      let tx = Int(parts[0]), let retx = Int(parts[1]) else { return nil }
                return .audioReport(txPackets: tx, retransmitted: retx)
            }),
        LogPattern(
            id: "le-connection-registered", category: "Server.MacCoex",
            format: "Adding LE Connection ", message: nil,
            verification: seen,
            meaning: "the coexistence manager registered an LE connection (repeats for one already up)",
            read: { _ in .connectionAdded(.le) }),
        LogPattern(
            id: "accessory-message", category: "Server.Accessory",
            format: "Device %{public}s Custom msg received ", message: nil,
            verification: seen,
            meaning: "a connected accessory sent the Mac a message — received, not sent",
            read: { _ in .accessoryMessage }),
        LogPattern(
            id: "accessory-message-echo", category: "CBStackAccessoryMonitor",
            format: "%{public}s", message: "Custom message received for device ",
            verification: seen,
            meaning: "the same accessory message, logged again by another component",
            read: { _ in .echo }),
        LogPattern(
            id: "controller-command", category: "Server.Core",
            format: "Sending: %{public}s", message: nil,
            verification: seen,
            meaning: "a command sent to the Bluetooth controller inside the Mac",
            read: { message in
                guard let name = groups(sending, message)?[0] else { return nil }
                return .controllerCommand(name)
            }),
        LogPattern(
            id: "wlan-status", category: "Server.Core",
            format: "Desense: WLAN Status: ", message: nil,
            verification: seen,
            meaning: "bluetoothd's own view of whether Wi-Fi is on",
            read: { message in
                guard let status = groups(wlanStatus, message)?[0] else { return nil }
                switch status.uppercased() {
                case "ON": return .wlanStatus(.on)
                case "OFF": return .wlanStatus(.off)
                default: return .wlanStatus(.unknown)
                }
            }),
        LogPattern(
            id: "device-found", category: "CBDiscovery",
            format: "Device found: ", message: nil,
            verification: seen,
            meaning: "a nearby device's advertisement was heard — received, not sent",
            read: { _ in .devicesHeard(1) }),
        LogPattern(
            id: "device-found-changed", category: "CBStackBLEScanner",
            format: "Device found changed: ", message: nil,
            verification: seen,
            meaning: "a nearby device's advertisement was heard again — received, not sent",
            read: { _ in .devicesHeard(1) }),
    ]

    // MARK: - Pieces

    private static func request(_ message: String) -> BluetoothEvent? {
        guard let parts = groups(xpcMessage, message) else { return nil }
        return .request(client(session: parts[1]), message: parts[0])
    }

    private static func link(_ kind: LinkKind, _ message: String) -> BluetoothEvent? {
        guard let parts = groups(linkReport, message),
              let txS = Int(parts[1]), let txF = Int(parts[2]),
              let rxS = Int(parts[3]), let rxF = Int(parts[4]) else { return nil }
        return .linkReport(kind, handle: parts[0], txSuccess: txS, txFailed: txF, rxSuccess: rxS, rxFailed: rxF)
    }

    /// bluetoothd names a client by session. Most sessions carry the process's name and pid
    /// ("com.apple.sharingd-MBF-666-563"); some carry only a pointer ("CBDaemon-0x…").
    package static func client(session: String) -> RadioClient {
        if let parts = groups(sessionWithPid, session), let pid = Int32(parts[1]) {
            let name = parts[0].split(separator: ".").last.map(String.init) ?? parts[0]
            return .process(name: name, pid: pid)
        }
        return .session(masked(session))
    }

    /// Pointer-like numbers differ on every run; masking them lets one client's sessions add up.
    package static func masked(_ session: String) -> String {
        let range = NSRange(session.startIndex..., in: session)
        return hexNumber.stringByReplacingMatches(in: session, range: range, withTemplate: "0x…")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    /// `log` writes "2026-10-04 14:03:11.123456-0400".
    package static func date(_ timestamp: String) -> Date? { dateFormatter.date(from: timestamp) }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a bad one is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let scanForProcess = regex(#"^Start scanning for process (.+?) \((\d+)\) with "#)
    private static let activeFlag = regex(#"\bactive: (\d)"#)
    private static let fromSession = regex(#"from session "([^"]+)""#)
    private static let toSession = regex(#"to session "([^"]+)""#)
    private static let startingScan = regex(#"Starting (\w+) scan"#)
    private static let bracketed = regex(#"\[([^\]\s]+)\]"#)
    private static let xpcMessage = regex(#"XPC message "([^"]+)" from session "([^"]+)""#)
    private static let linkReport = regex(
        #"^\w+ \[(0x[0-9A-Fa-f]+)\]: .*?tx \[S=\s*(\d+):F=\s*(\d+)\], rx \[S=\s*(\d+):F=\s*(\d+)\]"#)
    private static let beamforming = regex(#"Total tx packets =\s*(\d+), Total retx packets =\s*(\d+)"#)
    private static let sending = regex(#"^Sending: (\S+)"#)
    private static let wlanStatus = regex(#"^Desense: WLAN Status: (\w+)"#)
    private static let sessionWithPid = regex(#"^(.+?)-[A-Za-z]+-(\d+)-\d+$"#)
    private static let hexNumber = regex(#"0x[0-9A-Fa-f]+"#)

    /// The capture groups of the first match.
    private static func groups(_ pattern: NSRegularExpression, _ text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// The first capture group of every match.
    private static func allGroups(_ pattern: NSRegularExpression, _ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
