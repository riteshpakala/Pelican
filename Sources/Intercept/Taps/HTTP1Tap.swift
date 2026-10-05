import Foundation
import PelicanKit

/// Watches decrypted HTTP/1.1 going past and assembles it into exchanges.
///
/// Strictly a spectator: it is fed a copy of bytes that have already been forwarded, and it
/// cannot alter, delay or drop anything. If it ever gets confused it turns itself off for that
/// connection — a tap that cannot parse is a lost record, never a broken connection.
package struct HTTP1Tap: Sendable {

    /// Bodies are kept up to this much; the true size is always recorded.
    package static let bodyCap = 8 * 1_024 * 1_024
    /// A request or response line plus headers may not exceed this before the tap gives up.
    package static let headerCap = 256 * 1_024

    package private(set) var isDisabled = false
    /// Exchanges completed since they were last taken.
    package private(set) var completed: [InspectedExchange] = []

    private var request = Side()
    private var response = Side()
    /// Requests whose replies have not arrived yet, oldest first — HTTP/1.1 allows pipelining.
    private var waiting: [Pending] = []
    private let context: Context

    /// What the tap needs in order to label what it finds.
    package struct Context: Sendable {
        package var originName: String
        package var pid: Int32
        package var toolID: String?
        package var authority: String
        package var source: InspectedExchange.Source

        package init(originName: String, pid: Int32, toolID: String? = nil,
                     authority: String, source: InspectedExchange.Source) {
            self.originName = originName
            self.pid = pid
            self.toolID = toolID
            self.authority = authority
            self.source = source
        }
    }

    private struct Pending {
        var method: String
        var path: String
        var headers: [InspectedExchange.Header]
        var body: InspectedExchange.Body
        var startedAt: Date
    }

    package init(context: Context) {
        self.context = context
    }

    // MARK: - Feeding

    /// Bytes the client sent, already on their way upstream.
    package mutating func clientBytes(_ bytes: [UInt8]) {
        guard !isDisabled else { return }
        // Work on a copy: `consume` also appends to `self.completed`.
        var side = request
        do {
            try consume(bytes, into: &side, isRequest: true)
            request = side
        } catch {
            disable()
        }
    }

    /// Bytes the server sent, already on their way to the client.
    package mutating func serverBytes(_ bytes: [UInt8]) {
        guard !isDisabled else { return }
        var side = response
        do {
            try consume(bytes, into: &side, isRequest: false)
            response = side
        } catch {
            disable()
        }
    }

    /// Take the exchanges finished so far.
    package mutating func takeCompleted() -> [InspectedExchange] {
        defer { completed = [] }
        return completed
    }

    private mutating func disable() {
        isDisabled = true
        request = Side()
        response = Side()
        waiting = []
    }

    // MARK: - Parsing

    /// One direction's progress through the stream.
    private struct Side {
        enum Phase { case head, body, done }
        var phase: Phase = .head
        var buffer: [UInt8] = []
        var startLine = ""
        var headers: [InspectedExchange.Header] = []
        var captured: [UInt8] = []
        var wireBytes: UInt64 = 0
        var truncated = false
        var startedAt = Date()
        /// nil means "until the connection closes".
        var contentLength: Int?
        var chunked = false
        var chunkRemaining = 0
        var awaitingChunkSize = true
        /// 1xx, 204, 304 and replies to HEAD have no body whatever the headers say.
        var bodyless = false
    }

    private enum TapError: Error { case malformed }

    private mutating func consume(_ bytes: [UInt8], into side: inout Side, isRequest: Bool) throws {
        side.buffer += bytes
        var progressed = true
        while progressed {
            progressed = false
            switch side.phase {
            case .head:
                // Give up early on something that plainly is not HTTP, rather than buffering
                // a quarter of a megabyte of it first.
                if side.buffer.count >= 8, !looksLikeHTTPStart(side.buffer) { throw TapError.malformed }
                guard let end = findHeaderEnd(side.buffer) else {
                    if side.buffer.count > Self.headerCap { throw TapError.malformed }
                    return
                }
                let headText = String(decoding: side.buffer[..<end.headerLength], as: UTF8.self)
                side.buffer.removeFirst(end.total)
                try beginMessage(headText, into: &side, isRequest: isRequest)
                progressed = true

            case .body:
                if side.chunked {
                    progressed = try consumeChunked(into: &side)
                } else if let length = side.contentLength {
                    let wanted = length - Int(side.wireBytes)
                    guard wanted > 0 else { side.phase = .done; progressed = true; break }
                    let take = min(wanted, side.buffer.count)
                    guard take > 0 else { return }
                    append(Array(side.buffer[..<take]), to: &side)
                    side.buffer.removeFirst(take)
                    if Int(side.wireBytes) >= length { side.phase = .done }
                    progressed = take > 0
                } else {
                    // Until close: take whatever arrives and stay here.
                    guard !side.buffer.isEmpty else { return }
                    append(side.buffer, to: &side)
                    side.buffer = []
                    return
                }

            case .done:
                finish(&side, isRequest: isRequest)
                progressed = !side.buffer.isEmpty
            }
        }
    }

    private mutating func beginMessage(_ head: String, into side: inout Side, isRequest: Bool) throws {
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty, !lines[0].isEmpty else { throw TapError.malformed }
        side.startLine = lines.removeFirst()
        side.headers = []
        side.captured = []
        side.wireBytes = 0
        side.truncated = false
        side.contentLength = nil
        side.chunked = false
        side.awaitingChunkSize = true
        side.bodyless = false
        side.startedAt = Date()

        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw TapError.malformed }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            side.headers.append(InspectedExchange.Header(name: name.lowercased(), value: value))
            switch name.lowercased() {
            case "content-length": side.contentLength = Int(value)
            case "transfer-encoding": side.chunked = value.lowercased().contains("chunked")
            default: break
            }
        }

        if isRequest {
            let parts = side.startLine.split(separator: " ")
            guard parts.count >= 2 else { throw TapError.malformed }
            if parts[0] == "HEAD" { /* its reply is bodyless; noted when the reply starts */ }
        } else {
            let parts = side.startLine.split(separator: " ")
            guard parts.count >= 2, let status = Int(parts[1]) else { throw TapError.malformed }
            // Interim, no-content and not-modified replies never carry a body.
            if (100..<200).contains(status) || status == 204 || status == 304 { side.bodyless = true }
        }

        if side.bodyless || (side.contentLength == 0) {
            side.phase = .done
        } else if side.chunked || side.contentLength != nil || !isRequest {
            side.phase = .body
        } else {
            // A request with neither length nor chunking has no body.
            side.phase = .done
        }
    }

    /// chunked: a size line in hex, the data, then a zero-size line.
    private mutating func consumeChunked(into side: inout Side) throws -> Bool {
        if side.awaitingChunkSize {
            guard let newline = find(side.buffer, "\r\n") else {
                if side.buffer.count > Self.headerCap { throw TapError.malformed }
                return false
            }
            let line = String(decoding: side.buffer[..<newline], as: UTF8.self)
            side.buffer.removeFirst(newline + 2)
            let size = line.split(separator: ";").first.map(String.init) ?? line
            guard let value = Int(size.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw TapError.malformed
            }
            if value == 0 {
                side.phase = .done
                return true
            }
            side.chunkRemaining = value
            side.awaitingChunkSize = false
            return true
        }
        let take = min(side.chunkRemaining, side.buffer.count)
        guard take > 0 else { return false }
        append(Array(side.buffer[..<take]), to: &side)
        side.buffer.removeFirst(take)
        side.chunkRemaining -= take
        if side.chunkRemaining == 0 {
            // Step over the CRLF that ends the chunk.
            if side.buffer.count >= 2 { side.buffer.removeFirst(2) }
            side.awaitingChunkSize = true
        }
        return true
    }

    private func append(_ bytes: [UInt8], to side: inout Side) {
        side.wireBytes += UInt64(bytes.count)
        let room = Self.bodyCap - side.captured.count
        if room > 0 {
            side.captured += bytes.prefix(room)
            if bytes.count > room { side.truncated = true }
        } else if !bytes.isEmpty {
            side.truncated = true
        }
    }

    private mutating func finish(_ side: inout Side, isRequest: Bool) {
        let body = InspectedExchange.Body(
            text: String(decoding: side.captured, as: UTF8.self),
            wireByteCount: side.wireBytes,
            truncated: side.truncated,
            contentType: side.headers.first { $0.name == "content-type" }?.value)

        if isRequest {
            let parts = side.startLine.split(separator: " ").map(String.init)
            waiting.append(Pending(
                method: parts.first ?? "?",
                path: parts.count > 1 ? parts[1] : "/",
                headers: side.headers, body: body, startedAt: side.startedAt))
        } else if !waiting.isEmpty {
            let pending = waiting.removeFirst()
            let status = side.startLine.split(separator: " ").dropFirst().first.flatMap { Int($0) }
            completed.append(InspectedExchange(
                id: UUID().uuidString,
                startedAt: pending.startedAt,
                source: context.source,
                state: .complete,
                originName: context.originName,
                pid: context.pid,
                toolID: context.toolID,
                method: pending.method,
                authority: context.authority,
                path: pending.path,
                requestHeaders: pending.headers,
                requestBody: pending.body,
                responseStatus: status,
                responseHeaders: side.headers,
                responseBody: body))
        }
        side.phase = .head
        side.captured = []
    }

    // MARK: - Byte helpers

    /// An HTTP message starts with a method or "HTTP/", so its first bytes are printable
    /// ASCII with no control characters.
    private func looksLikeHTTPStart(_ bytes: [UInt8]) -> Bool {
        bytes.prefix(8).allSatisfy { byte in
            (byte >= 0x20 && byte < 0x7f) || byte == 0x09
        }
    }

    private func findHeaderEnd(_ bytes: [UInt8]) -> (headerLength: Int, total: Int)? {
        if let index = find(bytes, "\r\n\r\n") { return (index, index + 4) }
        if let index = find(bytes, "\n\n") { return (index, index + 2) }   // tolerant of bare LF
        return nil
    }

    private func find(_ bytes: [UInt8], _ needle: String) -> Int? {
        let pattern = Array(needle.utf8)
        guard bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) {
            if Array(bytes[start..<(start + pattern.count)]) == pattern { return start }
        }
        return nil
    }
}
