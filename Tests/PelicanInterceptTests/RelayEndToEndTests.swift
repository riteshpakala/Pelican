import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing
import X509
@testable import PelicanIntercept
@testable import PelicanKit

// MARK: - A real origin to talk to

/// A TLS server standing in for a vendor's API, with its own certificate authority — so the
/// engine's upstream certificate check is a real check, not a disabled one.
private final class TestOrigin {
    let group: EventLoopGroup
    let port: Int
    let caCertificate: NIOSSLCertificate
    private let channel: Channel
    /// Everything the origin received, so the relay can be proven byte-exact.
    private let received = Received()

    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        func append(_ more: [UInt8]) { lock.lock(); bytes += more; lock.unlock() }
        var all: [UInt8] { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    /// What to send back for each request received.
    private let reply: [UInt8]

    init(group: EventLoopGroup, hostname: String, reply: String) throws {
        self.group = group
        self.reply = Array(reply.utf8)

        // A one-off authority and a leaf for the hostname the client will ask for.
        let caKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let caName = try DistinguishedName { CommonName("Test origin CA") }
        let ca = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: caKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(3600),
            issuer: caName, subject: caName,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: caKey)
        let leafKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let leaf = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: leafKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(3600),
            issuer: caName, subject: try DistinguishedName { CommonName(hostname) },
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(hostname)])
            },
            issuerPrivateKey: caKey)

        caCertificate = try NIOSSLCertificate(bytes: ca.serializeAsPEM().derBytes, format: .der)
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [
                .certificate(try NIOSSLCertificate(bytes: leaf.serializeAsPEM().derBytes, format: .der)),
                .certificate(caCertificate),
            ],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: leafKey.serializeAsPEM().derBytes, format: .der)))
        let context = try NIOSSLContext(configuration: configuration)

        let received = self.received
        let replyBytes = self.reply
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: context)).flatMap {
                    channel.pipeline.addHandler(EchoingHandler(received: received, reply: replyBytes))
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        port = channel.localAddress?.port ?? 0
    }

    var receivedBytes: [UInt8] { received.all }

    func stop() { try? channel.close().wait() }

    /// Records what arrives, and answers once a request's headers are complete.
    private final class EchoingHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        private let received: Received
        private let reply: [UInt8]
        private var sawRequest = false

        init(received: Received, reply: [UInt8]) {
            self.received = received
            self.reply = reply
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
            received.append(bytes)
            guard !sawRequest, received.all.count >= 4 else { return }
            let text = String(decoding: received.all, as: UTF8.self)
            guard text.contains("\r\n\r\n") else { return }
            sawRequest = true
            var out = context.channel.allocator.buffer(capacity: reply.count)
            out.writeBytes(reply)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
    }
}

// MARK: - A client that goes through the proxy

/// Speaks CONNECT to the engine, then TLS to whatever answers — a client, as a tool would be.
private func throughProxy(
    group: EventLoopGroup, proxyPort: Int, host: String, originPort: Int,
    trusting roots: [NIOSSLCertificate], request: String, expectedReplyBytes: Int
) throws -> (reply: [UInt8], usedCertificate: [NIOSSLCertificate]) {
    var configuration = TLSConfiguration.makeClientConfiguration()
    configuration.trustRoots = .certificates(roots)
    let context = try NIOSSLContext(configuration: configuration)

    let collector = ReplyCollector(expected: expectedReplyBytes)
    let channel = try ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHandler(ProxyConnectHandler(
                host: host, port: originPort, tlsContext: context, serverHostname: host,
                request: Array(request.utf8), collector: collector))
        }
        .connect(host: "127.0.0.1", port: proxyPort).wait()
    defer { try? channel.close().wait() }
    try collector.wait(on: channel.eventLoop)
    return (collector.bytes, roots)
}

private final class ReplyCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private let expected: Int
    private var promise: EventLoopPromise<Void>?

    init(expected: Int) { self.expected = expected }

    func append(_ bytes: [UInt8]) {
        lock.lock()
        buffer += bytes
        let done = buffer.count >= expected
        let waiting = promise
        if done { promise = nil }
        lock.unlock()
        if done { waiting?.succeed(()) }
    }

    func fail(_ error: Error) {
        lock.lock()
        let waiting = promise
        promise = nil
        lock.unlock()
        waiting?.fail(error)
    }

    var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return buffer }

    func wait(on loop: EventLoop) throws {
        lock.lock()
        if buffer.count >= expected { lock.unlock(); return }
        let made = loop.makePromise(of: Void.self)
        promise = made
        lock.unlock()
        loop.scheduleTask(in: .seconds(10)) { made.fail(TimedOut()) }
        try made.futureResult.wait()
    }

    struct TimedOut: Error {}
}

/// Sends CONNECT, waits for 200, then starts TLS and sends the request.
private final class ProxyConnectHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let host: String
    private let port: Int
    private let tlsContext: NIOSSLContext
    private let serverHostname: String
    private let request: [UInt8]
    private let collector: ReplyCollector
    private var connected = false
    private var head: [UInt8] = []

    init(host: String, port: Int, tlsContext: NIOSSLContext, serverHostname: String,
         request: [UInt8], collector: ReplyCollector) {
        self.host = host
        self.port = port
        self.tlsContext = tlsContext
        self.serverHostname = serverHostname
        self.request = request
        self.collector = collector
    }

    func channelActive(context: ChannelHandlerContext) {
        let line = "CONNECT \(host):\(port) HTTP/1.1\r\nhost: \(host):\(port)\r\n\r\n"
        var out = context.channel.allocator.buffer(capacity: line.utf8.count)
        out.writeString(line)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        guard !connected else {
            collector.append(bytes)
            return
        }
        head += bytes
        let text = String(decoding: head, as: UTF8.self)
        guard let range = text.range(of: "\r\n\r\n") else { return }
        guard text.contains(" 200 ") else {
            collector.fail(InterceptError.badConnectRequest)
            context.close(promise: nil)
            return
        }
        connected = true
        head = []
        _ = range

        let tls = try! NIOSSLClientHandler(context: tlsContext, serverHostname: serverHostname)
        context.pipeline.addHandler(tls, position: .first).whenComplete { [request] _ in
            var out = context.channel.allocator.buffer(capacity: request.count)
            out.writeBytes(request)
            context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        collector.fail(error)
        context.close(promise: nil)
    }
}

// MARK: - Tests

@Suite(.serialized) struct RelayEndToEndTests {

    private let hostname = "api.anthropic.com"
    private let request = "POST /v1/messages HTTP/1.1\r\nhost: api.anthropic.com\r\ncontent-length: 20\r\n\r\n{\"prompt\":\"hello\"}\r\n"
    private let reply = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 18\r\n\r\n{\"reply\":\"hi\"}\r\n\r\n"

    /// Everything wired together: origin, engine, and a client talking through it.
    private func withEverything(
        inspecting: Bool,
        _ body: (InterceptEngine, TestOrigin, Int, [NIOSSLCertificate]) throws -> Void
    ) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }
        let origin = try TestOrigin(group: group, hostname: hostname, reply: reply)
        defer { origin.stop() }

        let authority = try LocalAuthority(permittedDomains: ["anthropic.com"])
        let policy = InterceptEngine.Policy(
            inspectedHosts: inspecting ? [.suffix("anthropic.com")] : [],
            originName: "claude", pid: 4242, toolID: "claude")
        let engine = InterceptEngine(authority: authority, policy: policy, group: group)
        // The origin is on loopback, but it is reached by its real name, so the engine's
        // certificate check is a real one against the origin's own authority.
        engine.upstreamTrustRoots = .certificates([origin.caCertificate])
        let originPort = origin.port
        engine.dial = { _, _ in (host: "127.0.0.1", port: originPort) }
        let proxyPort = try engine.start()
        defer { engine.stop() }

        // A client inspected by Pelican trusts Pelican's root; one being passed through
        // trusts the origin's.
        let roots = inspecting ? [try NIOSSLCertificate(bytes: authority.root.serializeAsPEM().derBytes, format: .der)]
                               : [origin.caCertificate]
        try body(engine, origin, proxyPort, roots)
    }

    @Test func anInspectedConversationIsReadAndTheBytesAreUnchanged() throws {
        try withEverything(inspecting: true) { engine, origin, proxyPort, roots in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try? group.syncShutdownGracefully() }
            let result = try throughProxy(
                group: group, proxyPort: proxyPort, host: hostname, originPort: origin.port,
                trusting: roots, request: request, expectedReplyBytes: reply.utf8.count)

            // The client got exactly what the origin sent.
            #expect(String(decoding: result.reply, as: UTF8.self) == reply)
            // The origin got exactly what the client sent.
            #expect(String(decoding: origin.receivedBytes, as: UTF8.self) == request)

            // And Pelican read the conversation.
            var captured: [InspectedExchange] = []
            for _ in 0..<50 where captured.isEmpty {
                captured = engine.exchanges.all
                if captured.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
            }
            let exchange = try #require(captured.first)
            #expect(exchange.method == "POST")
            #expect(exchange.path == "/v1/messages")
            #expect(exchange.authority == hostname)
            #expect(exchange.responseStatus == 200)
            #expect(exchange.requestBody.text.contains("hello"))
            #expect(exchange.responseBody.text.contains("hi"))
            #expect(exchange.originName == "claude")
            #expect(exchange.pid == 4242)
        }
    }

    @Test func aHostNobodyAskedToInspectIsPassedStraightThrough() throws {
        try withEverything(inspecting: false) { engine, origin, proxyPort, roots in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try? group.syncShutdownGracefully() }
            let result = try throughProxy(
                group: group, proxyPort: proxyPort, host: hostname, originPort: origin.port,
                trusting: roots, request: request, expectedReplyBytes: reply.utf8.count)

            // The client reached the real origin, verifying the origin's own certificate —
            // which is only possible if Pelican did not stand in the way.
            #expect(String(decoding: result.reply, as: UTF8.self) == reply)
            #expect(String(decoding: origin.receivedBytes, as: UTF8.self) == request)
            // Nothing was read.
            #expect(engine.exchanges.all.isEmpty)
        }
    }

    @Test func theProxyRefusesSomethingThatIsNotAConnect() throws {
        try withEverything(inspecting: true) { _, _, proxyPort, _ in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try? group.syncShutdownGracefully() }
            let reply = SimpleExchange.send("GET / HTTP/1.1\r\nhost: x\r\n\r\n",
                                            to: proxyPort, group: group)
            #expect(reply.contains("400"))
        }
    }
}

/// A plain TCP round trip, for checking the proxy's own replies.
private enum SimpleExchange {
    static func send(_ text: String, to port: Int, group: EventLoopGroup) -> String {
        let collector = ReplyCollector(expected: 12)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(Collecting(collector: collector, send: Array(text.utf8)))
            }
        let opened = try? bootstrap.connect(host: "127.0.0.1", port: port).wait()
        guard let channel = opened else { return "" }
        defer { try? channel.close().wait() }
        try? collector.wait(on: channel.eventLoop)
        return String(decoding: collector.bytes, as: UTF8.self)
    }

    private final class Collecting: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let collector: ReplyCollector
        let send: [UInt8]
        init(collector: ReplyCollector, send: [UInt8]) {
            self.collector = collector
            self.send = send
        }
        func channelActive(context: ChannelHandlerContext) {
            var out = context.channel.allocator.buffer(capacity: send.count)
            out.writeBytes(send)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            collector.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
        }
    }
}
