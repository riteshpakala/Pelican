import Foundation
import Testing
@testable import PelicanIntercept
@testable import PelicanKit

@Suite struct HTTP1TapTests {

    private func tap() -> HTTP1Tap {
        HTTP1Tap(context: .init(originName: "claude", pid: 1, toolID: "claude",
                                authority: "api.anthropic.com", source: .manualProxy))
    }
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private let request = """
        POST /v1/messages HTTP/1.1\r
        host: api.anthropic.com\r
        content-type: application/json\r
        content-length: 27\r
        \r
        {"messages":[{"a":"hello"}]}
        """
        .replacingOccurrences(of: "\n{", with: "\r\n{")

    @Test func readsARequestAndItsReply() throws {
        var tap = tap()
        tap.clientBytes(bytes("POST /v1/messages HTTP/1.1\r\nhost: api.anthropic.com\r\ncontent-length: 17\r\n\r\n{\"prompt\":\"hi\"}\r\n"))
        tap.serverBytes(bytes("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 14\r\n\r\n{\"ok\":true}\r\n\r\n"))
        let done = tap.takeCompleted()
        #expect(done.count == 1)
        let exchange = try #require(done.first)
        #expect(exchange.method == "POST")
        #expect(exchange.path == "/v1/messages")
        #expect(exchange.authority == "api.anthropic.com")
        #expect(exchange.responseStatus == 200)
        #expect(exchange.requestBody.text.contains("prompt"))
        #expect(exchange.requestBody.wireByteCount == 17)
        #expect(exchange.responseBody.text.contains("ok"))
        #expect(exchange.originName == "claude")
        #expect(exchange.toolID == "claude")
    }

    @Test func theSplitOfTheBytesNeverChangesTheResult() throws {
        let requestBytes = bytes("GET /a HTTP/1.1\r\nhost: x\r\n\r\n")
        let replyBytes = bytes("HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello")
        // Feed the same stream one byte at a time, and in a few larger slices.
        for chunk in [1, 3, 7, 1000] {
            var tap = tap()
            for piece in requestBytes.chunked(chunk) { tap.clientBytes(piece) }
            for piece in replyBytes.chunked(chunk) { tap.serverBytes(piece) }
            let done = tap.takeCompleted()
            #expect(done.count == 1, "chunk size \(chunk) produced \(done.count)")
            #expect(done.first?.responseBody.text == "hello", "chunk size \(chunk)")
        }
    }

    @Test func chunkedRepliesAreReassembled() throws {
        var tap = tap()
        tap.clientBytes(bytes("GET /stream HTTP/1.1\r\nhost: x\r\n\r\n"))
        tap.serverBytes(bytes("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"))
        tap.serverBytes(bytes("5\r\nhello\r\n"))
        tap.serverBytes(bytes("6\r\n world\r\n"))
        tap.serverBytes(bytes("0\r\n\r\n"))
        let exchange = try #require(tap.takeCompleted().first)
        #expect(exchange.responseBody.text == "hello world")
        #expect(exchange.responseBody.wireByteCount == 11)
    }

    @Test func repliesThatCannotHaveABodyAreNotLeftWaiting() throws {
        var tap = tap()
        tap.clientBytes(bytes("GET /a HTTP/1.1\r\nhost: x\r\n\r\n"))
        tap.serverBytes(bytes("HTTP/1.1 204 No Content\r\n\r\n"))
        tap.clientBytes(bytes("GET /b HTTP/1.1\r\nhost: x\r\n\r\n"))
        tap.serverBytes(bytes("HTTP/1.1 304 Not Modified\r\n\r\n"))
        let done = tap.takeCompleted()
        #expect(done.count == 2)
        #expect(done.map(\.path) == ["/a", "/b"])
        #expect(done.allSatisfy { $0.responseBody.wireByteCount == 0 })
    }

    @Test func pipelinedRequestsPairWithTheirOwnReplies() throws {
        var tap = tap()
        tap.clientBytes(bytes("GET /one HTTP/1.1\r\nhost: x\r\n\r\nGET /two HTTP/1.1\r\nhost: x\r\n\r\n"))
        tap.serverBytes(bytes("HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\nAAA"))
        tap.serverBytes(bytes("HTTP/1.1 201 Created\r\ncontent-length: 3\r\n\r\nBBB"))
        let done = tap.takeCompleted()
        #expect(done.map(\.path) == ["/one", "/two"])
        #expect(done.map(\.responseStatus) == [200, 201])
        #expect(done.map(\.responseBody.text) == ["AAA", "BBB"])
    }

    @Test func aBodyLargerThanTheCapRecordsItsRealSize() throws {
        var tap = tap()
        let size = HTTP1Tap.bodyCap + 1_000
        tap.clientBytes(bytes("GET /big HTTP/1.1\r\nhost: x\r\n\r\n"))
        tap.serverBytes(bytes("HTTP/1.1 200 OK\r\ncontent-length: \(size)\r\n\r\n"))
        tap.serverBytes([UInt8](repeating: 0x41, count: size))
        let exchange = try #require(tap.takeCompleted().first)
        #expect(exchange.responseBody.truncated)
        #expect(exchange.responseBody.wireByteCount == UInt64(size))
        #expect(exchange.responseBody.text.count == HTTP1Tap.bodyCap)
    }

    @Test func nonsenseTurnsTheTapOffRatherThanGuessing() {
        var tap = tap()
        // Binary that is not HTTP at all: noticed from its first bytes.
        tap.clientBytes([UInt8](repeating: 0xff, count: 64))
        #expect(tap.isDisabled)
        #expect(tap.takeCompleted().isEmpty)
        // Once off, it stays quiet; the connection itself is unaffected.
        tap.serverBytes(bytes("HTTP/1.1 200 OK\r\n\r\n"))
        #expect(tap.takeCompleted().isEmpty)
    }

    @Test func anOversizedHeaderBlockDisablesTheTap() {
        var tap = tap()
        tap.clientBytes(bytes("GET / HTTP/1.1\r\n"))
        tap.clientBytes(bytes(String(repeating: "x: y\r\n", count: 60_000)))
        #expect(tap.isDisabled)
    }

    @Test func aMalformedHeaderLineDisablesTheTap() {
        var tap = tap()
        tap.clientBytes(bytes("GET / HTTP/1.1\r\nthis line has no colon\r\n\r\n"))
        #expect(tap.isDisabled)
    }

    @Test func headersAreLowercasedSoTheyCanBeFound() throws {
        var tap = tap()
        tap.clientBytes(bytes("GET /a HTTP/1.1\r\nHost: X\r\nX-Api-Key: secret\r\n\r\n"))
        tap.serverBytes(bytes("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"))
        let exchange = try #require(tap.takeCompleted().first)
        #expect(exchange.requestHeaders.contains { $0.name == "x-api-key" })
        #expect(exchange.requestHeaders.allSatisfy { $0.name == $0.name.lowercased() })
    }
}

private extension Array where Element == UInt8 {
    func chunked(_ size: Int) -> [[UInt8]] {
        guard size > 0, !isEmpty else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
