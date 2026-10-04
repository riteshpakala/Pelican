import PelicanKit
import SwiftUI

/// The menubar's status lines for the watched Rao app: name and level, summary, first reason.
package struct RaoMenuStatus: View {
    @ObservedObject var monitor: TrustMonitor

    package init(monitor: TrustMonitor) { _monitor = ObservedObject(wrappedValue: monitor) }

    package var body: some View {
        let assessment = monitor.assessment
        Text("\(monitor.app.name): \(monitor.observing ? assessment.level.displayName : "not watching")")
        Text(assessment.summary)
        if let reason = assessment.reasons.first {
            Text(reason)
        }
    }
}
