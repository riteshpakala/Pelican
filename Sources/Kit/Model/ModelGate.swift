import Foundation

/// Serializes access to the one on-device model. Nothing stopped two generations from running
/// at once on a single `ModelContext` before; a background pass (Leak Guard) and a manual
/// analysis could step on each other. Callers wait their turn here.
///
/// Fair: turns are handed out in the order they were asked for. It lives in Kit rather than
/// beside the model because it knows nothing about MLX, so it can be tested on its own.
package actor ModelGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    /// Run `work` with exclusive use of the model. Waits until the model is free, and releases
    /// it afterwards even if `work` throws or is cancelled.
    package func run<T: Sendable>(_ work: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Hand the turn straight to the next waiter; `busy` stays true.
            waiters.removeFirst().resume()
        }
    }
}
