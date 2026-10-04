import PelicanKit
import SwiftUI

/// A pill saying how many things left, and whether Pelican read them or inferred them.
/// Solid for what was seen, outlined for what is only likely — the two never blur.
package struct ExposureBadge: View {
    private let seen: Int
    private let likely: Int

    package init(seen: Int, likely: Int) {
        self.seen = seen
        self.likely = likely
    }

    package var body: some View {
        if seen > 0 || likely > 0 {
            HStack(spacing: 4) {
                if seen > 0 {
                    Text("\(seen) seen")
                        .font(.pelicanSans(9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color.white)
                        .background(Capsule().fill(Color.pelicanError))
                }
                if likely > 0 {
                    Text("\(likely) likely")
                        .font(.pelicanSans(9.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color.pelicanInk.opacity(0.7))
                        .background(Capsule().strokeBorder(Color.pelicanInk.opacity(0.3), lineWidth: 1))
                }
            }
            .help(seen > 0
                  ? "\(seen) found in traffic Pelican could read\(likely > 0 ? ", \(likely) inferred from encrypted traffic" : "")"
                  : "\(likely) inferred from encrypted traffic — Pelican could not read it")
        }
    }
}

/// One finding, leading with whether it was seen or inferred, and saying what that rests on.
package struct ExposureRow: View {
    private let finding: ExposureFinding

    package init(finding: ExposureFinding) {
        self.finding = finding
    }

    package var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: finding.evidence.isSeen ? "eye.fill" : "eye.trianglebadge.exclamationmark")
                .font(.system(size: 10))
                .foregroundStyle(finding.evidence.isSeen
                                 ? Color.pelicanError
                                 : Color.pelicanInk.opacity(0.45))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.evidence.word)
                        .font(.pelicanSans(10, weight: .semibold))
                        .foregroundStyle(finding.evidence.isSeen
                                         ? Color.pelicanError
                                         : Color.pelicanInk.opacity(0.5))
                    Text(finding.subject)
                        .font(.pelicanSans(11.5, weight: .medium))
                        .foregroundStyle(Color.pelicanInk)
                    if let sample = finding.maskedSample {
                        Text(sample)
                            .font(.pelicanMono(10))
                            .foregroundStyle(Color.pelicanInk.opacity(0.5))
                    }
                    if finding.count > 1 {
                        Text("×\(finding.count)")
                            .font(.pelicanMono(9.5))
                            .foregroundStyle(Color.pelicanInk.opacity(0.4))
                    }
                }
                Text(because)
                    .font(.pelicanSans(10.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Always say what the claim rests on: where it was read, or what the guess is based on.
    private var because: String {
        switch finding.evidence {
        case .seen(let location):
            return "Read in the \(location) of a request from \(finding.originName) to \(finding.endpoint)."
        case .likely(let basis):
            return "Not read — \(basis.sentence)."
        }
    }
}

/// The findings for one screen, with a line saying what the two kinds mean.
package struct ExposureList: View {
    private let findings: [ExposureFinding]
    private let limit: Int

    package init(findings: [ExposureFinding], limit: Int = 8) {
        self.findings = findings
        self.limit = limit
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("What left this Mac")
            if findings.isEmpty {
                Text("Nothing noted today.")
                    .font(.pelicanSans(11.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.5))
            } else {
                ForEach(findings.prefix(limit)) { finding in
                    ExposureRow(finding: finding)
                }
                if findings.count > limit {
                    Text("and \(findings.count - limit) more")
                        .font(.pelicanSans(10.5))
                        .foregroundStyle(Color.pelicanInk.opacity(0.45))
                }
                Text("“Seen” means Pelican read it. “Likely” means the traffic was encrypted and Pelican is inferring from something it can name — never from the contents, which it cannot see.")
                    .font(.pelicanSans(10))
                    .foregroundStyle(Color.pelicanInk.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}
