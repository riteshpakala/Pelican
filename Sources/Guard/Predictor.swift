import Foundation
import PelicanKit

/// Destinations whose whole business is collecting what apps report. Matching one of these is
/// not an accusation: it says what kind of place the traffic went to, which is the only honest
/// thing to say about an encrypted connection.
package enum KnownCollectors {

    package struct Entry: Sendable, Hashable {
        package let pattern: HostPattern
        package let operatorName: String
        package let kind: String
        package let categories: [DataCategory]
    }

    package static let all: [Entry] = [
        // Crash and error reporting
        Entry(pattern: .suffix("sentry.io"), operatorName: "Sentry", kind: "error reports",
              categories: [.diagnostics]),
        Entry(pattern: .suffix("bugsnag.com"), operatorName: "Bugsnag", kind: "error reports",
              categories: [.diagnostics]),
        Entry(pattern: .suffix("crashlytics.com"), operatorName: "Crashlytics", kind: "crash reports",
              categories: [.diagnostics]),
        Entry(pattern: .suffix("rollbar.com"), operatorName: "Rollbar", kind: "error reports",
              categories: [.diagnostics]),
        // Product analytics
        Entry(pattern: .suffix("datadoghq.com"), operatorName: "Datadog", kind: "operational telemetry",
              categories: [.usage, .diagnostics]),
        Entry(pattern: .suffix("amplitude.com"), operatorName: "Amplitude", kind: "product analytics",
              categories: [.usage, .device]),
        Entry(pattern: .suffix("mixpanel.com"), operatorName: "Mixpanel", kind: "product analytics",
              categories: [.usage, .device]),
        Entry(pattern: .suffix("segment.io"), operatorName: "Segment", kind: "analytics routing",
              categories: [.usage, .device, .identity]),
        Entry(pattern: .suffix("segment.com"), operatorName: "Segment", kind: "analytics routing",
              categories: [.usage, .device, .identity]),
        Entry(pattern: .suffix("posthog.com"), operatorName: "PostHog", kind: "product analytics",
              categories: [.usage, .device]),
        Entry(pattern: .suffix("statsig.com"), operatorName: "Statsig", kind: "feature flags and metrics",
              categories: [.usage, .device]),
        Entry(pattern: .suffix("heap.io"), operatorName: "Heap", kind: "product analytics",
              categories: [.usage, .device]),
        Entry(pattern: .suffix("fullstory.com"), operatorName: "FullStory", kind: "session recording",
              categories: [.usage, .content]),
        Entry(pattern: .suffix("hotjar.com"), operatorName: "Hotjar", kind: "session recording",
              categories: [.usage, .content]),
        Entry(pattern: .suffix("logrocket.com"), operatorName: "LogRocket", kind: "session recording",
              categories: [.usage, .content]),
        Entry(pattern: .suffix("intercom.io"), operatorName: "Intercom", kind: "support messaging",
              categories: [.identity, .usage]),
        Entry(pattern: .suffix("launchdarkly.com"), operatorName: "LaunchDarkly", kind: "feature flags",
              categories: [.usage, .device]),
        Entry(pattern: .suffix("google-analytics.com"), operatorName: "Google Analytics",
              kind: "web analytics", categories: [.usage, .device]),
        Entry(pattern: .suffix("googletagmanager.com"), operatorName: "Google Tag Manager",
              kind: "web analytics", categories: [.usage, .device]),
        Entry(pattern: .suffix("doubleclick.net"), operatorName: "Google", kind: "advertising",
              categories: [.usage, .device]),
        Entry(pattern: .suffix("branch.io"), operatorName: "Branch", kind: "attribution",
              categories: [.usage, .device]),
        Entry(pattern: .suffix("appsflyer.com"), operatorName: "AppsFlyer", kind: "attribution",
              categories: [.usage, .device]),
        Entry(pattern: .suffix("adjust.com"), operatorName: "Adjust", kind: "attribution",
              categories: [.usage, .device]),
    ]

    /// Every hostname worth forward-resolving so these addresses are recognised. Suffix rules
    /// cannot be resolved, so this is the handful of exact intake hosts worth looking up.
    package static let hostnamesToResolve: [String] = [
        "http-intake.logs.us5.datadoghq.com",
        "browser-intake-us5-datadoghq.com",
        "api.amplitude.com",
        "api.mixpanel.com",
        "api.segment.io",
        "statsig.anthropic.com",
        "o1.ingest.sentry.io",
    ]

    package static func match(_ candidates: [String]) -> Entry? {
        for entry in all {
            if candidates.contains(where: entry.pattern.matches) { return entry }
        }
        return nil
    }
}

/// What earlier readable traffic to one endpoint carried. Categories and counts only — never
/// a value, so the profile cannot become a copy of what it describes.
package struct EndpointProfile: Sendable, Hashable, Codable, Identifiable {
    package var id: String        // originName|endpoint
    package var originName: String
    package var endpoint: String
    package var categories: [DataCategory]
    package var samples: Int
    package var since: Date
    package var lastSeen: Date

    /// Below this, one odd request would become a standing prediction.
    package static let minimumSamples = 5

    package var isConfident: Bool { samples >= Self.minimumSamples }
}

/// Says what encrypted traffic probably carries, and always says why.
package struct ExposurePredictor: Sendable {

    package init() {}

    /// A connection Pelican could not read. `claims` are what the vendor publishes about this
    /// endpoint; `profile` is what readable traffic to it carried before.
    package func predict(
        originName: String, toolID: String?, endpoint: String, candidates: [String],
        purposeNote: String? = nil, claims: [String] = [], profile: EndpointProfile? = nil,
        bytesOut: UInt64, bytesIn: UInt64, at time: Date
    ) -> [ExposureFinding] {
        var out: [ExposureFinding] = []

        func add(_ subject: String, _ category: DataCategory, _ basis: ExposureBasis,
                 _ detail: String, key: String = "") {
            out.append(ExposureFinding(
                id: "\(originName)|\(endpoint)|\(category.rawValue)|\(subject)|\(key)",
                subject: subject, category: category, evidence: .likely(basis), detail: detail,
                originName: originName, toolID: toolID, endpoint: endpoint,
                firstSeen: time, lastSeen: time))
        }

        // 1. What this Mac has actually seen go to this endpoint before.
        if let profile, profile.isConfident {
            for category in profile.categories {
                add(category.label, category,
                    .learned(samples: profile.samples, since: profile.since),
                    "Readable requests to \(endpoint) from \(originName) carried this before, so this one probably does too.")
            }
        }

        // 2. What kind of place it is.
        if let collector = KnownCollectors.match(candidates) {
            for category in collector.categories {
                add(category.label, category,
                    .collector("\(endpoint) is \(collector.operatorName), which collects \(collector.kind)"),
                    "This is a \(collector.kind) service. Pelican cannot read what was sent, only that it went there.")
            }
        }

        // 3. What the vendor says it carries. Each claim is its own finding — two claims
        // about one endpoint are two different things to check.
        for claim in claims {
            add("a claim about this endpoint", .usage, .documented(claim),
                "Pelican cannot check this without reading the traffic.",
                key: String(claim.prefix(40)))
        }

        // 4. How much left, compared with what came back.
        if bytesOut > 1_048_576, bytesIn > 0, bytesOut > bytesIn * 10 {
            add("more than a request's worth of data", .content,
                .volume("\(formatBytes(bytesOut)) went out against \(formatBytes(bytesIn)) back"),
                "An upload this lopsided is larger than a prompt alone; Pelican cannot see what it was.")
        }
        return out
    }
}
