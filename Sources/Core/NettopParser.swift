import Foundation

/// One flow row from a nettop sample, attributed to its owning process row.
struct NettopFlowSample: Sendable, Equatable {
    let processName: String
    let pid: Int32
    let proto: FlowProto
    let local: String
    let remote: String
    let interface: String
    let state: String
    let bytesIn: UInt64
    let bytesOut: UInt64
}

/// Pure parser for `nettop -x -L 1 -t external -J bytes_in,bytes_out,state,interface`.
///
/// The CSV interleaves process rows (`apsd.368,,,88867,282427,`) with the flow
/// rows belonging to them (`tcp4 10.0.0.132:49188<->17.57.144.23:5223,en0,Established,...`).
/// Flow rows are the ones containing `<->`. The name column may itself contain
/// commas/dots, so fields are split from the right using the fixed trailing
/// field count.
enum NettopParser {

    struct Result: Sendable {
        var flows: [NettopFlowSample]
        var skippedLines: Int
    }

    static func parse(_ csv: String) -> Result {
        var flows: [NettopFlowSample] = []
        var skipped = 0
        var currentProcess: (name: String, pid: Int32)?

        for line in csv.split(separator: "\n", omittingEmptySubsequences: true) {
            // Header: ",interface,state,bytes_in,bytes_out,"
            if line.hasPrefix(",") { continue }

            // Right-split: name column + 4 selected fields + trailing empty.
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 6 else { skipped += 1; continue }
            let name = parts[0..<(parts.count - 5)].joined(separator: ",")
            let interface = String(parts[parts.count - 5])
            let state = String(parts[parts.count - 4])
            let bytesIn = UInt64(parts[parts.count - 3]) ?? 0
            let bytesOut = UInt64(parts[parts.count - 2]) ?? 0

            if name.contains("<->") {
                guard let process = currentProcess,
                      let flow = parseFlow(
                        name, process: process, interface: interface,
                        state: state, bytesIn: bytesIn, bytesOut: bytesOut)
                else { skipped += 1; continue }
                flows.append(flow)
            } else {
                guard let process = parseProcess(name) else { skipped += 1; continue }
                currentProcess = process
            }
        }
        return Result(flows: flows, skippedLines: skipped)
    }

    /// "nxserver.bin.539" → ("nxserver.bin", 539). The pid is the trailing
    /// dot-separated digits; the name itself may contain dots.
    private static func parseProcess(_ name: String) -> (name: String, pid: Int32)? {
        guard let lastDot = name.lastIndex(of: "."),
              let pid = Int32(name[name.index(after: lastDot)...])
        else { return nil }
        return (String(name[..<lastDot]), pid)
    }

    /// "tcp4 10.0.0.132:49188<->17.57.144.23:5223" plus its process context.
    private static func parseFlow(
        _ column: String,
        process: (name: String, pid: Int32),
        interface: String, state: String,
        bytesIn: UInt64, bytesOut: UInt64
    ) -> NettopFlowSample? {
        guard let spaceIdx = column.firstIndex(of: " ") else { return nil }
        let proto = FlowProto(rawValue: String(column[..<spaceIdx])) ?? .other
        let endpoints = column[column.index(after: spaceIdx)...]
            .components(separatedBy: "<->")
        guard endpoints.count == 2 else { return nil }
        return NettopFlowSample(
            processName: process.name,
            pid: process.pid,
            proto: proto,
            local: endpoints[0],
            remote: endpoints[1],
            interface: interface,
            state: state,
            bytesIn: bytesIn,
            bytesOut: bytesOut
        )
    }

    /// Split a nettop endpoint into address and port. IPv4/quic4 print
    /// "addr:port"; IPv6 prints "addr.port" (the address contains colons).
    /// Wildcards ("*", "*.*", "*:*") yield an empty address / nil port.
    static func splitEndpoint(_ endpoint: String, proto: FlowProto) -> (address: String, port: UInt16?) {
        let separator: Character = proto.isIPv6 ? "." : ":"
        guard let idx = endpoint.lastIndex(of: separator) else {
            return (endpoint == "*" ? "" : endpoint, nil)
        }
        let address = String(endpoint[..<idx])
        let portString = String(endpoint[endpoint.index(after: idx)...])
        return (
            address == "*" ? "" : address,
            UInt16(portString)
        )
    }
}
