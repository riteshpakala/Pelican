import Foundation

/// What a client said in its TLS ClientHello, before anything is decrypted.
///
/// Pelican reads this itself rather than letting a TLS library do it, because the decision it
/// drives comes first: which host is being reached, whether the user asked for that host to be
/// inspected, and — if not — the bytes must be passed on untouched, exactly as they arrived.
package struct ClientHello: Sendable, Hashable {
    /// The server name the client asked for (SNI). Absent for an IP-address connection.
    package var serverName: String?
    /// The protocols the client offered, in its order of preference ("h2", "http/1.1").
    package var alpn: [String]
    /// The client hid its real server name (Encrypted Client Hello), so Pelican cannot know
    /// where this is going and must step aside.
    package var hasEncryptedClientHello: Bool
    /// How many bytes the hello occupied, so the caller can replay exactly those.
    package var byteCount: Int

    package init(serverName: String? = nil, alpn: [String] = [],
                 hasEncryptedClientHello: Bool = false, byteCount: Int = 0) {
        self.serverName = serverName
        self.alpn = alpn
        self.hasEncryptedClientHello = hasEncryptedClientHello
        self.byteCount = byteCount
    }

    /// Pelican can only mint a certificate for a name it knows.
    package var isInspectable: Bool { serverName != nil && !hasEncryptedClientHello }
}

package enum ClientHelloParse: Sendable, Equatable {
    case parsed(ClientHello)
    /// A valid start, but not all of it has arrived.
    case needMoreBytes
    /// Not a TLS handshake at all; whatever this is, Pelican should not touch it.
    case notTLS
}

package enum ClientHelloReader {

    /// The most a hello may occupy before Pelican gives up and passes the connection through.
    package static let maximumBytes = 65_536

    private static let handshakeRecord: UInt8 = 0x16
    private static let clientHelloType: UInt8 = 0x01
    private static let serverNameExtension: UInt16 = 0x0000
    private static let alpnExtension: UInt16 = 0x0010
    /// Both the standard code and the earlier draft one, so a client using either is noticed.
    private static let encryptedClientHelloExtensions: Set<UInt16> = [0xfe0d, 0xfe08]

    /// Read a ClientHello from the start of a connection.
    package static func read(_ bytes: [UInt8]) -> ClientHelloParse {
        var reader = Reader(bytes)
        // Record layer: a handshake record, whose body may be split across several records.
        guard let type = reader.byte() else { return .needMoreBytes }
        guard type == handshakeRecord else { return .notTLS }
        guard reader.skip(2), let recordLength = reader.be16() else { return .needMoreBytes }
        guard recordLength > 0 else { return .notTLS }

        // Gather the handshake body, following on into later records when it spans them.
        var body = [UInt8]()
        var remaining = Int(recordLength)
        while true {
            guard let chunk = reader.take(remaining) else { return .needMoreBytes }
            body += chunk
            // Is the handshake message complete yet?
            if body.count >= 4 {
                let declared = Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
                if body.count >= declared + 4 { break }
            }
            guard body.count < maximumBytes else { return .notTLS }
            // Another record of the same handshake.
            guard let nextType = reader.byte() else { return .needMoreBytes }
            guard nextType == handshakeRecord else { return .notTLS }
            guard reader.skip(2), let nextLength = reader.be16(), nextLength > 0 else {
                return .needMoreBytes
            }
            remaining = Int(nextLength)
        }

        var hello = Reader(body)
        guard let messageType = hello.byte() else { return .needMoreBytes }
        guard messageType == clientHelloType else { return .notTLS }
        guard hello.skip(3) else { return .needMoreBytes }          // handshake length
        guard hello.skip(2) else { return .needMoreBytes }          // legacy version
        guard hello.skip(32) else { return .needMoreBytes }         // random
        guard let sessionIDLength = hello.byte(), hello.skip(Int(sessionIDLength)) else {
            return .needMoreBytes
        }
        guard let cipherSuitesLength = hello.be16(), hello.skip(Int(cipherSuitesLength)) else {
            return .needMoreBytes
        }
        guard let compressionLength = hello.byte(), hello.skip(Int(compressionLength)) else {
            return .needMoreBytes
        }

        var result = ClientHello(byteCount: reader.offset)
        // Extensions are optional in the protocol; a hello without them simply has no SNI.
        guard let extensionsLength = hello.be16() else { return .parsed(result) }
        guard let extensions = hello.take(Int(extensionsLength)) else { return .needMoreBytes }

        var cursor = Reader(extensions)
        while let code = cursor.be16(), let length = cursor.be16() {
            guard let data = cursor.take(Int(length)) else { break }
            switch code {
            case serverNameExtension:
                result.serverName = parseServerName(data)
            case alpnExtension:
                result.alpn = parseALPN(data)
            case _ where encryptedClientHelloExtensions.contains(code):
                result.hasEncryptedClientHello = true
            default:
                break
            }
        }
        return .parsed(result)
    }

    /// server_name_list: a 2-byte length, then entries of type(1) + length(2) + name.
    private static func parseServerName(_ data: [UInt8]) -> String? {
        var reader = Reader(data)
        guard let listLength = reader.be16(), let list = reader.take(Int(listLength)) else { return nil }
        var entries = Reader(list)
        while let nameType = entries.byte(), let length = entries.be16() {
            guard let name = entries.take(Int(length)) else { return nil }
            guard nameType == 0 else { continue }            // 0 = host_name
            let text = String(decoding: name, as: UTF8.self)
            // A name with anything odd in it is not a name Pelican will act on.
            guard !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
            else { return nil }
            return text.lowercased()
        }
        return nil
    }

    /// protocol_name_list: a 2-byte length, then entries of length(1) + name.
    private static func parseALPN(_ data: [UInt8]) -> [String] {
        var reader = Reader(data)
        guard let listLength = reader.be16(), let list = reader.take(Int(listLength)) else { return [] }
        var entries = Reader(list)
        var out: [String] = []
        while let length = entries.byte() {
            guard length > 0, let name = entries.take(Int(length)) else { break }
            out.append(String(decoding: name, as: UTF8.self))
        }
        return out
    }

    /// A bounds-checked walk over bytes: every read either succeeds or says there are not enough.
    private struct Reader {
        private let bytes: [UInt8]
        private(set) var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func byte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func be16() -> UInt16? {
            guard offset + 1 < bytes.count else { return nil }
            defer { offset += 2 }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, offset + count <= bytes.count else { return false }
            offset += count
            return true
        }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }
    }
}
