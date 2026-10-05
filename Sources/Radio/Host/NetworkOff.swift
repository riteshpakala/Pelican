import CoreWLAN
import Foundation
import PelicanKit

/// A network service as macOS has it configured: a name, the interface it uses, and whether it
/// is enabled. Read from the system's own configuration, read-only.
package struct NetworkService: Sendable, Codable, Hashable, Identifiable {
    package var name: String
    package var interface: String?
    package var enabled: Bool
    /// The Wi-Fi service is switched by its radio's power, not by disabling the service.
    package var isWiFi: Bool

    package var id: String { name }

    package init(name: String, interface: String?, enabled: Bool, isWiFi: Bool) {
        self.name = name
        self.interface = interface
        self.enabled = enabled
        self.isWiFi = isWiFi
    }
}

/// What came of asking macOS to switch something off.
package enum SwitchOutcome: Sendable, Equatable {
    case done
    /// The person dismissed the authorization prompt. Not a failure.
    case cancelled
    case failed(String)

    package var isDone: Bool { self == .done }
}

/// Switching the Mac's network interfaces off and on again.
///
/// Every one of these is a *request to macOS*, not a guarantee: the same system Pelican is
/// watching carries them out, and nothing here powers a chip down. That is why the Radios screen
/// keeps watching the drivers' own counters afterwards — the switch is the ask, the counters are
/// the check.
package protocol NetworkSwitching: Sendable {
    func services() -> [NetworkService]
    func setWiFi(on: Bool) -> SwitchOutcome
    /// Enable or disable several services under one authorization prompt.
    func setServices(_ names: [String], on: Bool) -> SwitchOutcome
}

package struct LiveNetworkSwitch: NetworkSwitching {

    package init() {}

    /// macOS keeps the services in a root-owned plist. Reading needs nothing; changing one needs
    /// authorization, which is why `setServices` asks for it.
    package static let configuration = "/Library/Preferences/SystemConfiguration/preferences.plist"

    package func services() -> [NetworkService] {
        guard let data = FileManager.default.contents(atPath: Self.configuration),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let services = root["NetworkServices"] as? [String: Any]
        else { return [] }
        let wifiInterface = LiveRadioSystem.wifiInterfaceName()
        var out: [NetworkService] = []
        for (_, value) in services {
            guard let service = value as? [String: Any],
                  let name = service["UserDefinedName"] as? String else { continue }
            let interface = (service["Interface"] as? [String: Any])?["DeviceName"] as? String
            let hardware = (service["Interface"] as? [String: Any])?["Hardware"] as? String
            out.append(NetworkService(
                name: name, interface: interface,
                // macOS marks a disabled service with __INACTIVE__.
                enabled: (service["__INACTIVE__"] as? Int ?? 0) != 1,
                isWiFi: hardware == "AirPort" || (interface != nil && interface == wifiInterface)))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// CoreWLAN, the same switch as the menu bar's. Needs no authorization unless this Mac is
    /// configured to require it for Wi-Fi.
    package func setWiFi(on: Bool) -> SwitchOutcome {
        guard let interface = CWWiFiClient.shared().interface() else {
            return .failed("no Wi-Fi interface on this Mac")
        }
        do {
            try interface.setPower(on)
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// One `osascript` run holding every `networksetup` call, so the person authorizes once
    /// rather than once per service. No privileged helper is installed: the authorization lasts
    /// for this one command and nothing of it is kept.
    package func setServices(_ names: [String], on: Bool) -> SwitchOutcome {
        guard !names.isEmpty else { return .done }
        let commands = names.map { name in
            "/usr/sbin/networksetup -setnetworkserviceenabled \(Self.shellQuoted(name)) \(on ? "on" : "off")"
        }.joined(separator: "; ")
        let script = "do shell script \(Self.appleScriptQuoted(commands)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { return .failed(error.localizedDescription) }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .done }
        // -128 is AppleScript's "user cancelled".
        if message.contains("-128") || message.lowercased().contains("user canceled") { return .cancelled }
        let first = message.split(separator: "\n").first.map(String.init) ?? "networksetup failed"
        return .failed(first)
    }

    /// `it's` → `'it'\''s'`, so a service name can never be read as shell syntax.
    package static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The same text as an AppleScript string literal.
    package static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: "\"", with: #"\""#) + "\""
    }
}
