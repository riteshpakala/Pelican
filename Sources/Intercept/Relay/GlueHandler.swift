import NIOCore

/// Pumps bytes between two channels, in both directions, without changing them.
///
/// This is the part that must be invisible. It honours backpressure (it stops reading from one
/// side while the other is full), passes a half-close through as a half-close, and turns an
/// unclean shutdown into an unclean shutdown rather than a tidy ending the sender never sent.
/// A relay that quietly "fixes" any of those would change what the application sees.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    /// Reads held back because the partner is not writable.
    private var pendingRead = false

    private init() {}

    /// Join two channels. Each side's reads become the other side's writes.
    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    // MARK: - Lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClosed()
        context.fireChannelInactive()
    }

    // MARK: - Data

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The peer stopped sending but may still be receiving: pass that on exactly.
        if case .some(ChannelEvent.inputClosed) = event as? ChannelEvent {
            partner?.partnerCloseOutput()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Whatever went wrong here, the other side must not be left hanging.
        partner?.partnerClosed()
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        // Only pull more from this side when the other side can take it.
        if let partner, !partner.writable {
            pendingRead = true
        } else {
            context.read()
        }
    }

    // MARK: - Partner callbacks

    private var writable: Bool { context?.channel.isWritable ?? true }

    private func partnerWrite(_ buffer: ByteBuffer) {
        context?.write(wrapOutboundOut(buffer), promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerClosed() {
        context?.close(promise: nil)
    }

    /// The other side stopped sending, so this side stops sending too — a real half-close.
    private func partnerCloseOutput() {
        guard let context else { return }
        if context.channel.isActive {
            context.close(mode: .output, promise: nil)
        }
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
}
