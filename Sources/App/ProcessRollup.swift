import Foundation
import PelicanKit

/// Per-process grouping for the Processes screen.
struct ProcessRollup: Identifiable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    var flows: [Flow]
    var totalIn: UInt64 { flows.reduce(0) { $0 + $1.bytesIn } }
    var totalOut: UInt64 { flows.reduce(0) { $0 + $1.bytesOut } }
    var worstVerdict: Verdict? {
        flows.compactMap(\.verdict)
            .max { a, b in
                (a.label == .suspicious ? a.score : -1) < (b.label == .suspicious ? b.score : -1)
            }
    }
}
