import Foundation

/// One request and its reply, as the inspection engine will hand them over.
///
/// Defined here, not in the engine, so the UI and the detectors never depend on how the
/// traffic was read. Until inspection exists, these are only built by tests — the detectors
/// are written and checked against them now so they are ready when real ones arrive.
///
/// Credentials are masked by the engine before an exchange leaves it, and bodies are capped.
/// An exchange is never written to disk; only findings are, and those hold no values.
package struct InspectedExchange: Sendable, Hashable, Codable, Identifiable {

    /// How the traffic came to be readable.
    package enum Source: String, Sendable, Codable {
        /// A tool launched with Pelican's proxy in its environment.
        case manualProxy
        /// The system-extension tunnel.
        case tunnel
    }

    /// Why an exchange could not be read, when it could not.
    package enum Opacity: String, Sendable, Codable {
        case pinnedCertificate   // the client refused Pelican's certificate
        case hiddenServerName    // Encrypted Client Hello
        case notHTTP
        case quic
        case excluded            // the host was not one the user asked to inspect
    }

    package enum State: Sendable, Hashable, Codable {
        case inFlight
        case complete
        case reset
        /// Seen but not read, with the reason.
        case opaque(Opacity)
    }

    package struct Header: Sendable, Hashable, Codable {
        package var name: String
        package var value: String
        /// The engine replaced the value because it was a credential.
        package var masked: Bool

        package init(name: String, value: String, masked: Bool = false) {
            self.name = name
            self.value = value
            self.masked = masked
        }
    }

    package struct Body: Sendable, Hashable, Codable {
        /// Up to the engine's cap. Empty when nothing was captured.
        package var text: String
        /// What actually crossed the wire, whatever was captured.
        package var wireByteCount: UInt64
        package var truncated: Bool
        package var contentType: String?

        package init(text: String = "", wireByteCount: UInt64 = 0, truncated: Bool = false,
                     contentType: String? = nil) {
            self.text = text
            self.wireByteCount = wireByteCount
            self.truncated = truncated
            self.contentType = contentType
        }
    }

    package var id: String
    package var startedAt: Date
    package var source: Source
    package var state: State
    /// The process that made the request, and the tool it belongs to.
    package var originName: String
    package var pid: Int32
    package var toolID: String?
    package var method: String
    package var authority: String
    package var path: String
    package var requestHeaders: [Header]
    package var requestBody: Body
    package var responseStatus: Int?
    package var responseHeaders: [Header]
    package var responseBody: Body

    package init(id: String, startedAt: Date, source: Source, state: State, originName: String,
                 pid: Int32, toolID: String? = nil, method: String, authority: String, path: String,
                 requestHeaders: [Header] = [], requestBody: Body = Body(),
                 responseStatus: Int? = nil, responseHeaders: [Header] = [],
                 responseBody: Body = Body()) {
        self.id = id
        self.startedAt = startedAt
        self.source = source
        self.state = state
        self.originName = originName
        self.pid = pid
        self.toolID = toolID
        self.method = method
        self.authority = authority
        self.path = path
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseStatus = responseStatus
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
    }

    package var endpoint: String { authority + path }

    /// Everything a detector should read, each with a name for where it came from, so a
    /// finding can say where it was found.
    package var scannable: [(where: String, text: String)] {
        var out: [(String, String)] = [("path", path)]
        for header in requestHeaders where !header.masked {
            out.append(("request header \(header.name)", header.value))
        }
        if !requestBody.text.isEmpty { out.append(("request body", requestBody.text)) }
        for header in responseHeaders where !header.masked {
            out.append(("response header \(header.name)", header.value))
        }
        if !responseBody.text.isEmpty { out.append(("response body", responseBody.text)) }
        return out
    }
}
