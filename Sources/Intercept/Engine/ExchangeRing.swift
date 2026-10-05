import Foundation
import PelicanKit

/// The exchanges Pelican has read, newest last, bounded by both count and captured bytes.
///
/// Memory only, on purpose: decrypted traffic is never written to disk. Quitting Pelican
/// forgets all of it; only Leak Guard's findings — which hold no values — are kept.
package final class ExchangeRing: @unchecked Sendable {

    package static let maximumCount = 500
    package static let maximumBytes = 128 * 1_024 * 1_024

    private let lock = NSLock()
    private var items: [InspectedExchange] = []
    private var bytes = 0
    /// Told about each exchange as it completes, on whatever thread finished it.
    private var observers: [(InspectedExchange) -> Void] = []

    package init() {}

    package func append(_ exchange: InspectedExchange) {
        lock.lock()
        items.append(exchange)
        bytes += exchange.requestBody.text.utf8.count + exchange.responseBody.text.utf8.count
        while items.count > Self.maximumCount || (bytes > Self.maximumBytes && items.count > 1) {
            let dropped = items.removeFirst()
            bytes -= dropped.requestBody.text.utf8.count + dropped.responseBody.text.utf8.count
        }
        let listeners = observers
        lock.unlock()
        for listener in listeners { listener(exchange) }
    }

    package func observe(_ handler: @escaping (InspectedExchange) -> Void) {
        lock.lock()
        observers.append(handler)
        lock.unlock()
    }

    /// Newest first, for showing.
    package var all: [InspectedExchange] {
        lock.lock(); defer { lock.unlock() }
        return items.reversed()
    }

    package var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    package func removeAll() {
        lock.lock(); defer { lock.unlock() }
        items = []
        bytes = 0
    }
}
