import Foundation
import Testing
@testable import PelicanIntercept

// MARK: - Building a ClientHello to read back

/// Assembles a TLS ClientHello the way a client does, so the reader is tested against the
/// real shape rather than a convenient one.
private struct HelloBuilder {
    var serverName: String? = "api.anthropic.com"
    var alpn: [String] = ["h2", "http/1.1"]
    var encryptedClientHello = false
    var sessionIDLength = 32
    /// Split the handshake across this many records (1 = the usual single record).
    var records = 1

    private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }

    private var extensions: [UInt8] {
        var out: [UInt8] = []
        if let serverName {
            let name = Array(serverName.utf8)
            var entry: [UInt8] = [0]                    // host_name
            entry += be16(name.count) + name
            var list = be16(entry.count) + entry
            list = be16(list.count - 2) + Array(list.dropFirst(2))  // keep the list length honest
            out += be16(0x0000) + be16(list.count) + list
        }
        if !alpn.isEmpty {
            var names: [UInt8] = []
            for proto in alpn { names += [UInt8(proto.utf8.count)] + Array(proto.utf8) }
            let list = be16(names.count) + names
            out += be16(0x0010) + be16(list.count) + list
        }
        if encryptedClientHello {
            out += be16(0xfe0d) + be16(4) + [0, 0, 0, 0]
        }
        return out
    }

    private var handshakeBody: [UInt8] {
        var out: [UInt8] = []
        out += [0x03, 0x03]                                     // legacy version
        out += [UInt8](repeating: 0xab, count: 32)              // random
        out += [UInt8(sessionIDLength)] + [UInt8](repeating: 0xcd, count: sessionIDLength)
        out += be16(4) + [0x13, 0x01, 0x13, 0x02]               // cipher suites
        out += [1, 0]                                           // compression methods
        let extensions = self.extensions
        out += be16(extensions.count) + extensions
        return out
    }

    /// The full handshake message, framed in one or more TLS records.
    func build() -> [UInt8] {
        let body = handshakeBody
        var message: [UInt8] = [0x01]                           // client_hello
        message += [UInt8(body.count >> 16 & 0xff), UInt8(body.count >> 8 & 0xff), UInt8(body.count & 0xff)]
        message += body

        var out: [UInt8] = []
        let perRecord = (message.count + records - 1) / max(records, 1)
        var index = 0
        while index < message.count {
            let chunk = Array(message[index..<min(index + perRecord, message.count)])
            out += [0x16, 0x03, 0x01] + be16(chunk.count) + chunk
            index += perRecord
        }
        return out
    }
}

// MARK: - Tests

@Suite struct ClientHelloTests {

    private func read(_ bytes: [UInt8]) -> ClientHelloParse { ClientHelloReader.read(bytes) }

    @Test func readsTheServerNameAndOfferedProtocols() throws {
        guard case .parsed(let hello) = read(HelloBuilder().build()) else {
            Issue.record("did not parse"); return
        }
        #expect(hello.serverName == "api.anthropic.com")
        #expect(hello.alpn == ["h2", "http/1.1"])
        #expect(!hello.hasEncryptedClientHello)
        #expect(hello.isInspectable)
        // The byte count must cover exactly the hello, so it can be replayed verbatim.
        #expect(hello.byteCount == HelloBuilder().build().count)
    }

    @Test func aHelloSplitAcrossRecordsIsStillRead() throws {
        guard case .parsed(let hello) = read(HelloBuilder(records: 3).build()) else {
            Issue.record("did not parse a split hello"); return
        }
        #expect(hello.serverName == "api.anthropic.com")
        #expect(hello.alpn == ["h2", "http/1.1"])
    }

    @Test func aPartialHelloAsksForMoreRatherThanGuessing() {
        let full = HelloBuilder().build()
        // Every prefix short of the whole thing must be incomplete, never a wrong answer.
        for length in stride(from: 1, to: full.count, by: 7) {
            let parse = read(Array(full.prefix(length)))
            #expect(parse == .needMoreBytes, "a \(length)-byte prefix parsed as \(parse)")
        }
    }

    @Test func somethingThatIsNotTLSIsLeftAlone() {
        #expect(read(Array("GET / HTTP/1.1\r\n\r\n".utf8)) == .notTLS)
        #expect(read([0x17, 0x03, 0x03, 0x00, 0x05]) == .notTLS)   // application data, not a handshake
        #expect(read([]) == .needMoreBytes)
    }

    @Test func aHiddenServerNameMeansPelicanMustStepAside() throws {
        guard case .parsed(let hello) = read(HelloBuilder(encryptedClientHello: true).build()) else {
            Issue.record("did not parse"); return
        }
        #expect(hello.hasEncryptedClientHello)
        #expect(!hello.isInspectable)
    }

    @Test func aConnectionWithNoServerNameIsNotInspectable() throws {
        guard case .parsed(let hello) = read(HelloBuilder(serverName: nil).build()) else {
            Issue.record("did not parse"); return
        }
        #expect(hello.serverName == nil)
        #expect(!hello.isInspectable)
        // Its protocols are still readable.
        #expect(hello.alpn == ["h2", "http/1.1"])
    }

    @Test func anEmptySessionIDParses() throws {
        guard case .parsed(let hello) = read(HelloBuilder(sessionIDLength: 0).build()) else {
            Issue.record("did not parse"); return
        }
        #expect(hello.serverName == "api.anthropic.com")
    }

    @Test func aNameWithOddCharactersIsRefused() throws {
        guard case .parsed(let hello) = read(HelloBuilder(serverName: "evil host\u{0}.com").build()) else {
            Issue.record("did not parse"); return
        }
        // Rather than act on a name it cannot trust, the reader reports none.
        #expect(hello.serverName == nil)
        #expect(!hello.isInspectable)
    }

    @Test func truncatedExtensionsDoNotCrashOrInvent() throws {
        var bytes = HelloBuilder().build()
        // Chop the last few bytes off the record body but keep the record header honest.
        bytes.removeLast(3)
        let parse = read(bytes)
        // Either incomplete or parsed with less — never a wrong server name.
        if case .parsed(let hello) = parse {
            #expect(hello.serverName == nil || hello.serverName == "api.anthropic.com")
        }
    }
}
