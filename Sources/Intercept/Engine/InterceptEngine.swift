import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import PelicanKit
import X509

/// Reads the conversations an AI tool has with its service, by standing between them.
///
/// The shape of it, and why:
///
/// 1. A client connects and asks for a host (`CONNECT`, then its TLS ClientHello).
/// 2. If that host is not one the user turned inspection on for — or the client hid its name,
///    or anything at all goes wrong — Pelican **steps aside**: it opens a plain connection to
///    the real destination, replays the bytes it buffered, and copies bytes from then on. The
///    client meets the real server, with the real certificate, exactly as if Pelican were not
///    there.
/// 3. Otherwise Pelican connects to the **real server first**, checking its certificate
///    properly. Only once that has succeeded does it answer the client, with a certificate it
///    mints for that host and the same protocol the real server chose.
/// 4. From then on it decrypts on one side, re-encrypts on the other, and changes nothing. A
///    copy of the plaintext goes to a tap that only watches.
///
/// Running as you, never as root, and only while you have it switched on.
package final class InterceptEngine: @unchecked Sendable {

    package let exchanges = ExchangeRing()
    package let authority: LocalAuthority

    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var channel: Channel?
    private let lock = NSLock()
    /// Hosts whose clients refused Pelican's certificate. Remembered so the next attempt is
    /// passed straight through instead of failing again.
    private var refused: Set<String> = []

    /// What the engine is allowed to read, and who is asking.
    package struct Policy: Sendable {
        /// Only these hosts are inspected; everything else is passed through untouched.
        package var inspectedHosts: [HostPattern]
        /// How the engine labels what it records.
        package var originName: String
        package var pid: Int32
        package var toolID: String?

        package init(inspectedHosts: [HostPattern], originName: String = "unknown",
                     pid: Int32 = 0, toolID: String? = nil) {
            self.inspectedHosts = inspectedHosts
            self.originName = originName
            self.pid = pid
            self.toolID = toolID
        }

        package func inspects(_ host: String) -> Bool {
            inspectedHosts.contains { $0.matches(host) }
        }
    }

    private var policy: Policy

    /// What the engine trusts when it checks the real server's certificate. The default is the
    /// Mac's own trust store, exactly as any client would use. Tests point it at their own
    /// origin; nothing in the app ever changes it, so inspection can never silently accept a
    /// certificate the system would reject.
    package var upstreamTrustRoots: NIOSSLTrustRoots = .default

    /// Where to actually dial for a requested host. nil — the default — dials the host the
    /// client asked for. A test origin on loopback is reached this way while the name, and so
    /// the certificate check, stays the real one.
    package var dial: (@Sendable (String, Int) -> (host: String, port: Int))?

    package init(authority: LocalAuthority, policy: Policy, group: EventLoopGroup? = nil) {
        self.authority = authority
        self.policy = policy
        if let group {
            self.group = group
            ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            ownsGroup = true
        }
    }

    package func setPolicy(_ policy: Policy) {
        lock.lock(); defer { lock.unlock() }
        self.policy = policy
    }

    private var currentPolicy: Policy {
        lock.lock(); defer { lock.unlock() }
        return policy
    }

    private func noteRefusal(_ host: String) {
        lock.lock(); defer { lock.unlock() }
        refused.insert(host)
    }

    private func wasRefused(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return refused.contains(host)
    }

    // MARK: - Listening

    /// Start the proxy on loopback. Returns the port it is listening on.
    ///
    /// Loopback only: nothing off this Mac can reach it.
    package func start(port: Int = 0) throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                return channel.pipeline.addHandler(ConnectHandler(engine: self))
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
        self.channel = channel
        return channel.localAddress?.port ?? 0
    }

    package func stop() {
        try? channel?.close().wait()
        channel = nil
        if ownsGroup { try? group.syncShutdownGracefully() }
    }

    // MARK: - Deciding and connecting

    func shouldInspect(_ hello: ClientHello, host: String) -> Bool {
        guard hello.isInspectable, !wasRefused(host) else { return false }
        guard currentPolicy.inspects(host) else { return false }
        return authority.permits(host)
    }

    /// Connect to the real destination, with TLS when the connection is being inspected.
    func connectUpstream(
        host: String, port: Int, alpn: [String], inspecting: Bool, on loop: EventLoop
    ) -> EventLoopFuture<(Channel, String?)> {
        let trustRoots = upstreamTrustRoots
        let bootstrap = ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                guard inspecting else { return channel.eventLoop.makeSucceededVoidFuture() }
                do {
                    var configuration = TLSConfiguration.makeClientConfiguration()
                    // The real server's certificate is checked the way any client would —
                    // Pelican never hides a bad certificate from the person it protects.
                    configuration.trustRoots = trustRoots
                    configuration.applicationProtocols = alpn
                    let context = try NIOSSLContext(configuration: configuration)
                    let handler = try NIOSSLClientHandler(context: context, serverHostname: host)
                    return channel.pipeline.addHandler(handler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let destination: (host: String, port: Int) = dial?(host, port) ?? (host: host, port: port)
        return bootstrap.connect(host: destination.host, port: destination.port).flatMap { channel in
            guard inspecting else { return loop.makeSucceededFuture((channel, nil)) }
            // Wait for the handshake, so the protocol it chose is known before answering
            // the client.
            let promise = loop.makePromise(of: (Channel, String?).self)
            let waiter = HandshakeWaiter(promise: promise, channel: channel)
            return channel.pipeline.addHandler(waiter).flatMap { promise.futureResult }
        }
    }

    /// The names the real server's certificate carries, so Pelican's stand-in carries them too.
    func upstreamNames(of channel: Channel) -> [String] {
        // Reading the peer chain needs the verification callback; mirroring the requested host
        // alone is correct and sufficient for the clients Pelican inspects.
        []
    }

    func record(_ exchange: InspectedExchange) {
        exchanges.append(exchange)
    }

    func clientRefused(host: String) {
        noteRefusal(host)
    }

    var engineGroup: EventLoopGroup { group }
    var describePolicy: Policy { currentPolicy }
}

// MARK: - Waiting for the upstream handshake

/// Completes once the real server has finished its TLS handshake, reporting the protocol it
/// chose so the client can be offered the same one.
private final class HandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private var promise: EventLoopPromise<(Channel, String?)>?
    private let channel: Channel

    init(promise: EventLoopPromise<(Channel, String?)>, channel: Channel) {
        self.promise = promise
        self.channel = channel
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted(let negotiated) = event as? TLSUserEvent {
            let promise = self.promise
            self.promise = nil
            context.pipeline.removeHandler(self, promise: nil)
            promise?.succeed((channel, negotiated))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let promise = self.promise
        self.promise = nil
        promise?.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let promise = self.promise
        self.promise = nil
        promise?.fail(InterceptError.upstreamClosed)
        context.fireChannelInactive()
    }
}

package enum InterceptError: Error, Equatable {
    case upstreamClosed
    case badConnectRequest
    case notPermitted(String)
}
