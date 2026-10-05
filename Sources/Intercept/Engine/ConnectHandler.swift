import Foundation
import NIOCore
import NIOSSL
import NIOTLS
import PelicanKit

/// Reads the `CONNECT host:port` a client sends to a proxy, answers it, and hands the
/// connection to the peek handler.
final class ConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let engine: InterceptEngine
    private var buffer: [UInt8] = []

    /// A request line and its headers may not exceed this.
    private static let requestCap = 8 * 1_024

    init(engine: InterceptEngine) {
        self.engine = engine
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer += incoming.readBytes(length: incoming.readableBytes) ?? []
        guard let end = headerEnd(buffer) else {
            if buffer.count > Self.requestCap { context.close(promise: nil) }
            return
        }
        let head = String(decoding: buffer[..<end.length], as: UTF8.self)
        let rest = Array(buffer[end.total...])
        buffer = []

        guard let target = Self.parseConnect(head) else {
            let message = "HTTP/1.1 400 Bad Request\r\nconnection: close\r\n\r\n"
            var out = context.channel.allocator.buffer(capacity: message.utf8.count)
            out.writeString(message)
            context.writeAndFlush(wrapOutboundOut(out)).whenComplete { _ in
                context.close(promise: nil)
            }
            return
        }

        let message = "HTTP/1.1 200 Connection Established\r\n\r\n"
        var out = context.channel.allocator.buffer(capacity: message.utf8.count)
        out.writeString(message)
        context.writeAndFlush(wrapOutboundOut(out)).whenComplete { [engine] _ in
            let peek = PeekHandler(engine: engine, host: target.host, port: target.port)
            context.pipeline.addHandler(peek, position: .after(self)).whenComplete { _ in
                context.pipeline.removeHandler(self, promise: nil)
                // Anything that arrived with the CONNECT belongs to the peek handler.
                if !rest.isEmpty {
                    var carried = context.channel.allocator.buffer(capacity: rest.count)
                    carried.writeBytes(rest)
                    context.fireChannelRead(self.wrapInboundOut(carried))
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    static func parseConnect(_ head: String) -> (host: String, port: Int)? {
        guard let line = head.split(separator: "\r\n", omittingEmptySubsequences: false).first
                ?? head.split(separator: "\n", omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else { return nil }
        let target = parts[1]
        guard let colon = target.lastIndex(of: ":") else { return nil }
        let host = String(target[..<colon]).lowercased()
        guard let port = Int(target[target.index(after: colon)...]), port > 0, port < 65_536,
              !host.isEmpty else { return nil }
        return (host, port)
    }

    private func headerEnd(_ bytes: [UInt8]) -> (length: Int, total: Int)? {
        let crlf = Array("\r\n\r\n".utf8), lf = Array("\n\n".utf8)
        if let index = Self.find(bytes, crlf) { return (index, index + 4) }
        if let index = Self.find(bytes, lf) { return (index, index + 2) }
        return nil
    }

    static func find(_ bytes: [UInt8], _ pattern: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count, !pattern.isEmpty else { return nil }
        for start in 0...(bytes.count - pattern.count)
        where Array(bytes[start..<(start + pattern.count)]) == pattern {
            return start
        }
        return nil
    }
}

/// Buffers the start of the connection until the TLS ClientHello can be read, then either
/// inspects or steps aside — replaying every buffered byte either way, so the client's
/// handshake is never altered.
final class PeekHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let engine: InterceptEngine
    private let host: String
    private let port: Int
    private var buffer: [UInt8] = []
    private var decided = false

    init(engine: InterceptEngine, host: String, port: Int) {
        self.engine = engine
        self.host = host
        self.port = port
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !decided else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer += incoming.readBytes(length: incoming.readableBytes) ?? []

        switch ClientHelloReader.read(buffer) {
        case .needMoreBytes:
            if buffer.count > ClientHelloReader.maximumBytes { stepAside(context, hello: nil) }
        case .notTLS:
            stepAside(context, hello: nil)
        case .parsed(let hello):
            decided = true
            if engine.shouldInspect(hello, host: host) {
                inspect(context, hello: hello)
            } else {
                stepAside(context, hello: hello)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - Pass through, untouched

    /// Connect to the real destination and copy bytes. Pelican reads nothing and changes
    /// nothing; the client meets the real server and its real certificate.
    private func stepAside(_ context: ChannelHandlerContext, hello: ClientHello?) {
        decided = true
        let carried = buffer
        buffer = []
        let channel = context.channel
        engine.connectUpstream(host: host, port: port, alpn: [], inspecting: false,
                               on: context.eventLoop)
            .whenComplete { result in
                switch result {
                case .failure:
                    channel.close(promise: nil)
                case .success(let (upstream, _)):
                    Self.glue(client: channel, upstream: upstream, tap: nil, carried: carried,
                              clientPipelinePosition: nil)
                }
            }
    }

    // MARK: - Inspect

    private func inspect(_ context: ChannelHandlerContext, hello: ClientHello) {
        let carried = buffer
        buffer = []
        let channel = context.channel
        let host = self.host
        let engine = self.engine
        let policy = engine.describePolicy

        engine.connectUpstream(host: host, port: port, alpn: hello.alpn, inspecting: true,
                               on: context.eventLoop)
            .whenComplete { result in
                switch result {
                case .failure:
                    // The real server could not be reached, or its certificate did not check
                    // out. The client must see that, not a Pelican-signed success.
                    channel.close(promise: nil)
                case .success(let (upstream, negotiated)):
                    do {
                        let (leaf, key) = try engine.authority.leaf(
                            for: host, upstreamNames: engine.upstreamNames(of: upstream))
                        let chain = try engine.authority.chain(for: leaf).map { certificate in
                            NIOSSLCertificateSource.certificate(try NIOSSLCertificate(
                                bytes: certificate.serializeAsPEM().derBytes, format: .der))
                        }
                        var configuration = TLSConfiguration.makeServerConfiguration(
                            certificateChain: chain,
                            privateKey: .privateKey(try NIOSSLPrivateKey(
                                bytes: key.serializeAsPEM().derBytes, format: .der)))
                        // Offer the client exactly what the real server chose.
                        configuration.applicationProtocols = negotiated.map { [$0] } ?? []
                        let serverContext = try NIOSSLContext(configuration: configuration)
                        let tls = NIOSSLServerHandler(context: serverContext)

                        // Only HTTP/1.1 is read today; anything else is relayed correctly and
                        // recorded as not readable.
                        let readable = (negotiated ?? "http/1.1") == "http/1.1"
                        let tap = readable
                            ? HTTP1Tap.Shared(HTTP1Tap(context: .init(
                                originName: policy.originName, pid: policy.pid,
                                toolID: policy.toolID, authority: host, source: .manualProxy)),
                                              engine: engine)
                            : nil
                        if !readable {
                            engine.record(Self.opaque(host: host, policy: policy, reason: .notHTTP))
                        }

                        channel.pipeline.addHandler(tls, position: .first).whenComplete { _ in
                            Self.glue(client: channel, upstream: upstream, tap: tap,
                                      carried: carried, clientPipelinePosition: tls)
                        }
                    } catch {
                        upstream.close(promise: nil)
                        channel.close(promise: nil)
                    }
                }
            }
    }

    private static func opaque(host: String, policy: InterceptEngine.Policy,
                               reason: InspectedExchange.Opacity) -> InspectedExchange {
        InspectedExchange(
            id: UUID().uuidString, startedAt: Date(), source: .manualProxy,
            state: .opaque(reason), originName: policy.originName, pid: policy.pid,
            toolID: policy.toolID, method: "", authority: host, path: "")
    }

    /// Join the two channels, optionally teeing plaintext into a tap, and replay whatever was
    /// buffered before the decision.
    private static func glue(client: Channel, upstream: Channel, tap: HTTP1Tap.Shared?,
                             carried: [UInt8], clientPipelinePosition: ChannelHandler?) {
        let (clientGlue, upstreamGlue) = GlueHandler.matchedPair()
        let clientSide: [ChannelHandler] = tap.map { [TapHandler(tap: $0, fromClient: true), clientGlue] }
            ?? [clientGlue]
        let upstreamSide: [ChannelHandler] = tap.map { [TapHandler(tap: $0, fromClient: false), upstreamGlue] }
            ?? [upstreamGlue]

        let clientReady = client.pipeline.addHandlers(clientSide)
        let upstreamReady = upstream.pipeline.addHandlers(upstreamSide)

        clientReady.and(upstreamReady).whenComplete { result in
            switch result {
            case .failure:
                client.close(promise: nil)
                upstream.close(promise: nil)
            case .success:
                guard !carried.isEmpty else { return }
                var replay = client.allocator.buffer(capacity: carried.count)
                replay.writeBytes(carried)
                if clientPipelinePosition != nil {
                    // Being inspected: the buffered ClientHello belongs to the TLS handler
                    // that was just installed in front of everything.
                    client.pipeline.fireChannelRead(NIOAny(replay))
                    client.pipeline.fireChannelReadComplete()
                } else {
                    // Stepping aside: the bytes go upstream exactly as they arrived.
                    upstream.writeAndFlush(NIOAny(replay), promise: nil)
                }
            }
        }
    }
}

/// Copies plaintext into a tap after forwarding it, so the tap can never affect the connection.
final class TapHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let tap: HTTP1Tap.Shared
    private let fromClient: Bool

    init(tap: HTTP1Tap.Shared, fromClient: Bool) {
        self.tap = tap
        self.fromClient = fromClient
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        // Forward first: whatever the tap does next cannot delay the connection.
        context.fireChannelRead(data)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        tap.feed(bytes, fromClient: fromClient)
    }
}

extension HTTP1Tap {
    /// A tap shared by the two directions of one connection.
    final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var tap: HTTP1Tap
        private let engine: InterceptEngine

        init(_ tap: HTTP1Tap, engine: InterceptEngine) {
            self.tap = tap
            self.engine = engine
        }

        func feed(_ bytes: [UInt8], fromClient: Bool) {
            lock.lock()
            if fromClient { tap.clientBytes(bytes) } else { tap.serverBytes(bytes) }
            let done = tap.takeCompleted()
            lock.unlock()
            for exchange in done { engine.record(exchange) }
        }
    }
}
