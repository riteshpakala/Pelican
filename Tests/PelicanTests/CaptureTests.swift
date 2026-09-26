import Darwin
import Foundation
import Testing
@testable import Pelican

@Suite struct NettopParserTests {
    let csv = """
    ,interface,state,bytes_in,bytes_out,
    sewn-server.9910,,,91330,8440,
    tcp4 127.0.0.1:47091<->127.0.0.1:54025,lo0,Established,91330,8440,
    tcp4 127.0.0.1:47080<->*:*,lo0,Listen,,,
    com.apple.WebKit.Networking.812,,,10,20,
    tcp6 fe80::1%utun4.51234<->fe80::2%utun4.443,utun4,CloseWait,10,20,
    udp4 *:5353<->*:*,,,,,
    garbage line without fields
    """

    @Test func parsesLoopbackIPv6AndDottedNames() {
        let result = NettopParser.parse(csv)
        #expect(result.flows.count == 4)
        #expect(result.skippedLines == 1)
        let established = result.flows[0]
        #expect(established.processName == "sewn-server" && established.pid == 9910)
        #expect(established.remote == "127.0.0.1:54025" && established.interface == "lo0")
        let webkit = result.flows[2]
        #expect(webkit.processName == "com.apple.WebKit.Networking" && webkit.pid == 812)
        #expect(webkit.proto == .tcp6 && webkit.state == "CloseWait")
    }

    @Test func splitsEndpointsTheWayNettopPrintsThem() {
        #expect(NettopParser.splitEndpoint("127.0.0.1:47080", proto: .tcp4) == ("127.0.0.1", 47080))
        #expect(NettopParser.splitEndpoint("fe80::1%utun4.443", proto: .tcp6) == ("fe80::1%utun4", 443))
        #expect(NettopParser.splitEndpoint("*:*", proto: .udp4) == ("", nil))
        #expect(NettopParser.splitEndpoint("*.5353", proto: .udp6) == ("", 5353))
    }
}

@Suite struct FlowStateTests {
    @Test func mapsEverySpellingAndKeepsUnknowns() {
        for label in ["Established", "Listen", "SynSent", "SynReceived", "FinWait1", "FinWait2",
                      "CloseWait", "Closing", "LastAck", "TimeWait", "Closed"] {
            #expect(FlowState(label: label).label == label)
        }
        #expect(FlowState(label: "") == .none)
        #expect(FlowState(label: "Bogus") == .unknown("Bogus"))
        #expect(FlowState(label: "TimeWait").isTerminal)
        #expect(!FlowState(label: "Established").isTerminal)
    }

    @Test func codesAsItsLabel() throws {
        let data = try JSONEncoder().encode([FlowState.closeWait, .unknown("Odd")])
        #expect(String(data: data, encoding: .utf8) == "[\"CloseWait\",\"Odd\"]")
        #expect(try JSONDecoder().decode([FlowState].self, from: data) == [.closeWait, .unknown("Odd")])
    }

    @Test func scopeRecognisesLoopback() {
        #expect(FlowScope.of(interface: "lo0", local: "10.0.0.2", remote: "10.0.0.3") == .loopback)
        #expect(FlowScope.of(interface: "", local: "127.0.0.1", remote: "127.0.0.1") == .loopback)
        #expect(FlowScope.of(interface: "", local: "::1", remote: "") == .loopback)
        #expect(FlowScope.of(interface: "en0", local: "10.0.0.2", remote: "1.1.1.1") == .external)
    }
}

@Suite struct EndpointFormatTests {
    private func data(ipv4 address: String, port: UInt16) -> Data {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &sin.sin_addr)
        return Data(bytes: &sin, count: MemoryLayout<sockaddr_in>.size)
    }

    private func data(ipv6 address: String, port: UInt16) -> Data {
        var sin6 = sockaddr_in6()
        sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.sin6_family = sa_family_t(AF_INET6)
        sin6.sin6_port = port.bigEndian
        inet_pton(AF_INET6, address, &sin6.sin6_addr)
        return Data(bytes: &sin6, count: MemoryLayout<sockaddr_in6>.size)
    }

    @Test func rendersIPv4LikeNettopAndRoundTrips() throws {
        let decoded = try #require(EndpointFormat.decode(data(ipv4: "172.66.147.243", port: 443)))
        let text = EndpointFormat.string(address: decoded.address, port: decoded.port, ipv6: decoded.ipv6)
        #expect(text == "172.66.147.243:443")
        #expect(NettopParser.splitEndpoint(text, proto: .tcp4) == ("172.66.147.243", 443))
    }

    @Test func rendersWildcardsLikeNettop() throws {
        let any4 = try #require(EndpointFormat.decode(data(ipv4: "0.0.0.0", port: 0)))
        #expect(EndpointFormat.string(address: any4.address, port: any4.port, ipv6: false) == "*:*")
        let any6 = try #require(EndpointFormat.decode(data(ipv6: "::", port: 5353)))
        #expect(EndpointFormat.string(address: any6.address, port: any6.port, ipv6: true) == "*.5353")
    }

    @Test func rendersIPv6WithDotPort() throws {
        let decoded = try #require(EndpointFormat.decode(data(ipv6: "2606:4700::6812:1", port: 443)))
        let text = EndpointFormat.string(address: decoded.address, port: decoded.port, ipv6: true)
        #expect(text == "2606:4700::6812:1.443")
        #expect(NettopParser.splitEndpoint(text, proto: .tcp6) == ("2606:4700::6812:1", 443))
    }

    @Test func nstatDescriptionBecomesASample() throws {
        let keys = NStatAPI.Keys()
        let description: [String: Any] = [
            keys.pid: NSNumber(value: 4242), keys.processName: "Ambient", keys.provider: "TCP",
            keys.local: data(ipv4: "10.0.0.5", port: 50000), keys.remote: data(ipv4: "1.2.3.4", port: 443),
            keys.tcpState: "Established", keys.rxBytes: NSNumber(value: 10), keys.txBytes: NSNumber(value: 20),
            keys.epid: NSNumber(value: 4242),
        ]
        let sample = try #require(NStatFlowSource.sample(from: description, keys: keys))
        #expect(sample.proto == .tcp4 && sample.local == "10.0.0.5:50000" && sample.remote == "1.2.3.4:443")
        #expect(sample.bytesIn == 10 && sample.bytesOut == 20 && sample.effectivePid == nil)
        #expect(sample.origin == .nstat)
    }

    @Test func unconnectedSocketsAreNotFlowsYet() {
        let keys = NStatAPI.Keys()
        let preConnect: [String: Any] = [
            keys.pid: NSNumber(value: 1), keys.provider: "TCP", keys.tcpState: "Closed",
            keys.local: data(ipv4: "0.0.0.0", port: 0), keys.remote: data(ipv4: "0.0.0.0", port: 0),
        ]
        #expect(NStatFlowSource.sample(from: preConnect, keys: keys) == nil)
        var listener = preConnect
        listener[keys.tcpState] = "Listen"
        listener[keys.local] = data(ipv4: "127.0.0.1", port: 47080)
        #expect(NStatFlowSource.sample(from: listener, keys: keys)?.local == "127.0.0.1:47080")
    }
}

@Suite struct NetworkMonitorMergeTests {
    private func sample(_ remote: String = "1.2.3.4:443", state: String = "Established", in bytesIn: UInt64 = 0,
                        origin: FlowSourceKind) -> FlowSample {
        FlowSample(processName: "Ambient", pid: 7, proto: .tcp4, local: "10.0.0.5:50000", remote: remote,
                   interface: "en0", state: state, bytesIn: bytesIn, bytesOut: 0, origin: origin)
    }

    @Test func eventSourceOwnsLifecycleAndOpensOnce() async {
        let monitor = NetworkMonitor()
        await monitor.inject(.upsert(sample(origin: .nstat), token: 1, at: Date()))
        await monitor.inject(.snapshot([sample(in: 5, origin: .nettop)], skipped: 0, at: Date()))
        var events = await monitor.takeEventsForTesting()
        #expect(events.count == 1)
        guard case .opened(let flow, _) = events[0] else { Issue.record("expected an open"); return }
        #expect(flow.seenBy == [.nstat])
        #expect(await monitor.activeFlowsForTesting.first?.seenBy == [.nstat, .nettop])

        // nettop no longer lists it: NStat still owns it, so it stays open.
        await monitor.inject(.snapshot([], skipped: 0, at: Date()))
        #expect(await monitor.activeFlowsForTesting.count == 1)
        #expect(await monitor.takeEventsForTesting().isEmpty)

        // NStat's removal closes it; a late nettop row doesn't reopen it.
        await monitor.inject(.removed(token: 1, at: Date()))
        await monitor.inject(.snapshot([sample(origin: .nettop)], skipped: 0, at: Date()))
        events = await monitor.takeEventsForTesting()
        #expect(events.count == 1)
        if case .closed(let closed, _) = events[0] { #expect(closed.bytesIn == 5) } else { Issue.record("expected a close") }
        #expect(await monitor.activeFlowsForTesting.isEmpty)
    }

    @Test func pollingOwnsWhatEventsNeverSaw() async {
        let monitor = NetworkMonitor()
        await monitor.inject(.snapshot([sample(origin: .nettop)], skipped: 0, at: Date()))
        await monitor.inject(.snapshot([], skipped: 0, at: Date()))
        let events = await monitor.takeEventsForTesting()
        #expect(events.count == 2)
        if case .closed = events[1] {} else { Issue.record("nettop should close its own flow") }
    }

    @Test func acceptedConnectionInListenStateIsInbound() async {
        let monitor = NetworkMonitor()
        await monitor.inject(.upsert(sample("127.0.0.1:55025", state: "Listen", origin: .nstat), token: 9, at: Date()))
        #expect(await monitor.activeFlowsForTesting.first?.direction == .inbound)
    }
}
