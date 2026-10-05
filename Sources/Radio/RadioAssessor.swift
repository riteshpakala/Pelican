import Foundation
import PelicanKit

/// Where the radios stand at a glance. Never a claim that nothing was sent: the Mac can only
/// count what passes through its own software, so the calm state is "nothing seen".
package enum RadioStanding: Sendable, Equatable {
    /// Not watching.
    case paused
    /// Two things that cannot both be true: a transmission while a radio was reported off, or
    /// packets on an interface or airtime on a radio that was off.
    case contradiction(Int)
    /// Neither bluetoothd's log nor the Bluetooth chip's transport can be read, so Pelican knows
    /// nothing — which must never look calm.
    case blind(String)
    /// The Bluetooth radio sent something while Wi-Fi was off and Lockdown Mode on.
    case lockedDown(minutes: Int)
    /// The Bluetooth radio sent something today, outside the locked-down posture.
    case transmitting(minutes: Int)
    /// Nothing seen, within what the Mac counts and reports.
    case nothingReported
}

package enum RadioAssessor {

    /// Blind only when both sources are: either one alone still sees the Bluetooth radio.
    package static func standing(day: RadioDay, observing: Bool, source: FlowSourceStatus,
                                 transports: FlowSourceStatus) -> RadioStanding {
        guard observing else { return .paused }
        let contradictions = day.contradictions.count
        if contradictions > 0 { return .contradiction(contradictions) }
        if source != .running, transports != .running {
            switch (source, transports) {
            case (.unavailable(let log), .unavailable(let counters)): return .blind("\(log); \(counters)")
            case (.unavailable(let reason), _), (_, .unavailable(let reason)): return .blind(reason)
            default: return .blind("starting")
            }
        }
        let lockedDown = day.lockedDownTransmittingMinutes
        if lockedDown > 0 { return .lockedDown(minutes: lockedDown) }
        let transmitting = day.transmittingMinutes
        return transmitting > 0 ? .transmitting(minutes: transmitting) : .nothingReported
    }
}
