import Foundation

package struct AnalysisPreset: Identifiable, Hashable {
    package let name: String
    package let symbol: String
    package let summary: String
    package let prompt: String

    package var id: String { name }
}

extension AnalysisPreset {
    package static let all: [AnalysisPreset] = [
        AnalysisPreset(
            name: "Beaconing",
            symbol: "metronome",
            summary: "Periodic small callbacks to the same remote",
            prompt: """
            Flag flows that look like command-and-control beaconing: long-lived or \
            repeatedly re-opened connections to the same remote host with small, \
            similar-sized byte deltas over time. Ignore well-known Apple push/OS \
            services (apsd, courier.push.apple.com, port 5223) and NTP.
            """
        ),
        AnalysisPreset(
            name: "Exfil-sized transfers",
            symbol: "arrow.up.circle.dotted",
            summary: "Outbound volume far exceeding inbound",
            prompt: """
            Flag flows where outbound bytes greatly exceed inbound bytes (more than \
            10x and over 1 MB total) to destinations that are not well-known CDNs, \
            software-update hosts, or cloud sync services. Large uploads to unknown \
            destinations are the signal.
            """
        ),
        AnalysisPreset(
            name: "Unexpected talkers",
            symbol: "person.crop.circle.badge.questionmark",
            summary: "Processes that shouldn't need the network",
            prompt: """
            Flag processes whose names suggest they should not need network access — \
            text editors, PDF/image viewers, screensavers, calculators, shell \
            utilities — yet have outbound flows. A benign app phoning home is worth \
            a low score; a shell tool talking to a raw IP is worth a high one.
            """
        ),
        AnalysisPreset(
            name: "Raw-IP destinations",
            symbol: "number.circle",
            summary: "Outbound to IPs with no DNS name",
            prompt: """
            Flag outbound flows to remote IPs whose reverse-DNS host is "-" (no \
            name), especially on non-standard ports. Malware frequently connects \
            straight to hard-coded IPs and skips DNS. CDN and cloud provider IPs \
            without PTR records on port 443 deserve a lower score.
            """
        ),
        AnalysisPreset(
            name: "Odd ports & protocols",
            symbol: "questionmark.app.dashed",
            summary: "Unusual ports or protocol choices",
            prompt: """
            Flag outbound flows on unusual ports — anything that is not a \
            well-known service port (80, 443, 53, 123, 5223, 993, 587, 22) — plus \
            UDP to high ports and QUIC to hosts that are not major CDNs. Consider \
            whether the port fits the process.
            """
        ),
        AnalysisPreset(
            name: "Privacy exposure",
            symbol: "eye.trianglebadge.exclamationmark",
            summary: "Where personal information is likely to go",
            prompt: """
            Flag flows that are likely to carry personal information off this Mac: \
            connections to analytics, telemetry, crash-reporting or advertising \
            hosts (names containing analytics, telemetry, metrics, intake, events, \
            sentry, segment, amplitude, mixpanel, datadog, doubleclick), uploads \
            much larger than their replies, and AI tools sending to hosts other \
            than their own model API. You cannot see contents — say what the \
            destination and volume suggest, not what was sent. A well-known \
            model API carrying a prompt is expected and worth a low score.
            """
        ),
    ]
}
