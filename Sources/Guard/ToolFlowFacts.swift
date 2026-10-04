import Foundation

/// What Leak Guard needs to know about one AI-tool connection.
///
/// A plain value, so the guard never imports the AI tools module and the two stay independent:
/// the app converts what it has into this.
package struct ToolFlowFacts: Sendable, Hashable {
    /// The process the connection came from — a tool, or something it ran.
    package var originName: String
    package var toolID: String?
    /// The destination as it is best known: a hostname where there is one, else the address.
    package var endpoint: String
    /// Every name that could be this address.
    package var candidates: [String]
    package var bytesOut: UInt64
    package var bytesIn: UInt64
    package var at: Date

    package init(originName: String, toolID: String? = nil, endpoint: String,
                 candidates: [String] = [], bytesOut: UInt64, bytesIn: UInt64, at: Date) {
        self.originName = originName
        self.toolID = toolID
        self.endpoint = endpoint
        self.candidates = candidates
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.at = at
    }
}
