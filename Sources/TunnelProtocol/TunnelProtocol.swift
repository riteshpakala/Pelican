import Foundation

// The small, Foundation-only contract between the app and its network extension. Both link it;
// it pulls in nothing else, so the root extension stays minimal.

/// One connection the extension saw, reported to the app. The extension declines every flow
/// (so traffic goes direct, untouched); this is what it observed on the way past.
///
/// Identity is deliberately thin: the pid and the signing identifier macOS attaches to the
/// flow. The app does the richer attribution with its own process tree and catalog — the
/// extension does no code-signature reads of its own.
public struct FlowObservation: Codable, Sendable, Hashable {
    public var pid: Int32
    /// The source's code-signing identifier, as macOS reports it on the flow (may be empty).
    public var signingIdentifier: String
    public var remoteHost: String?
    public var remoteAddress: String
    public var remotePort: Int
    public var isOutbound: Bool
    public var at: Date

    public init(pid: Int32, signingIdentifier: String, remoteHost: String?,
                remoteAddress: String, remotePort: Int, isOutbound: Bool, at: Date) {
        self.pid = pid
        self.signingIdentifier = signingIdentifier
        self.remoteHost = remoteHost
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.isOutbound = isOutbound
        self.at = at
    }
}

/// What the app asks the extension to do. Sent with NETunnelProviderSession.sendProviderMessage.
public enum TunnelRequest: Codable, Sendable {
    /// Are you alive? Replied to with `.pong`.
    case ping
    /// Hand over the connections seen since the last drain.
    case drain
    /// The address ranges to watch. A flow to anything else is never offered to the extension.
    case setRanges([String])
}

public enum TunnelReply: Codable, Sendable {
    case pong
    case observations([FlowObservation])
    case ok
}

public enum TunnelCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
