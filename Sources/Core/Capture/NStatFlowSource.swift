import Darwin
import Foundation

/// Event-driven capture through NetworkStatistics.framework — the private framework
/// `/usr/bin/nettop` is built on (Objective-See's open-source Netiquette uses it the same way).
/// The kernel pushes every socket's add, description, counts and removal, so a connection
/// that opens and closes in a few milliseconds is still seen. Loaded with dlopen/dlsym: if a
/// symbol is missing on some macOS release, `make()` fails and Pelican runs on nettop alone.
///
/// LIMIT: without Apple's private `com.apple.private.network.statistics` entitlement (nettop
/// has it; no third-party app can), the kernel reports only kernel sockets — BSD sockets such
/// as curl's or SwiftNIO's. Connections made through the user-space network stack
/// (URLSession / Network.framework) are reported to nettop but not here, which is why the
/// nettop poll runs beside this source rather than only as a fallback.
///
/// All callbacks run on `queue` (the queue handed to NStatManagerCreate), which also owns
/// every mutable field here.
final class NStatFlowSource: FlowSource, @unchecked Sendable {
    let kind: FlowSourceKind = .nstat

    struct LoadError: Error { let reason: String }

    static func make() -> Result<NStatFlowSource, LoadError> {
        NStatAPI.load().map { NStatFlowSource(api: $0) }
    }

    private let api: NStatAPI
    private let queue = DispatchQueue(label: "pelican.capture.nstat", qos: .utility)
    private var manager: UnsafeMutableRawPointer?
    private var sink: AsyncStream<FlowSourceEvent>.Continuation?
    private var nextToken: UInt64 = 0
    private var merged: [UInt64: [String: Any]] = [:]
    private var lastYield: [UInt64: FlowSample] = [:]
    /// Live source objects, so a socket first described before it connected can be asked
    /// again once its counts show it doing something.
    private var sourceRefs: [UInt64: UnsafeMutableRawPointer] = [:]
    private var lastRequery: [UInt64: Date] = [:]
    private var refreshTimer: DispatchSourceTimer?
    private var cadence: Double = 4

    private init(api: NStatAPI) {
        self.api = api
    }

    func start(into sink: AsyncStream<FlowSourceEvent>.Continuation) {
        queue.async { self.startOnQueue(sink) }
    }

    func setCadence(_ seconds: Double) {
        queue.async {
            self.cadence = max(0.5, seconds)
            if self.manager != nil { self.scheduleRefresh() }
        }
    }

    func stop() {
        queue.async {
            self.refreshTimer?.cancel()
            self.refreshTimer = nil
            if let manager = self.manager { self.api.destroy(manager) }
            self.manager = nil
            self.merged = [:]
            self.lastYield = [:]
            self.sourceRefs = [:]
            self.lastRequery = [:]
            self.sink?.yield(.status(.nstat, .stopped))
            self.sink = nil
        }
    }

    // MARK: - Queue-confined

    private func startOnQueue(_ sink: AsyncStream<FlowSourceEvent>.Continuation) {
        guard manager == nil else { return }
        self.sink = sink
        let added: NStatAPI.AddedBlock = { [weak self] source, _ in
            guard let self, let source else { return }
            self.nextToken += 1
            // A token of our own: the framework reuses source pointers after a removal.
            let token = self.nextToken
            self.sourceRefs[token] = source
            self.api.setDescriptionBlock(source) { [weak self] dict in self?.update(token, dict) }
            self.api.setCountsBlock(source) { [weak self] dict in self?.update(token, dict) }
            self.api.setRemovedBlock(source) { [weak self] in self?.remove(token) }
            self.api.queryDescription(source)
        }
        guard let manager = api.create(nil, Unmanaged.passUnretained(queue).toOpaque(), added) else {
            sink.yield(.status(.nstat, .unavailable("NStatManagerCreate returned nothing")))
            return
        }
        self.manager = manager
        _ = api.addAllTCP(manager, 0, 0)
        _ = api.addAllUDP(manager, 0, 0)
        sink.yield(.status(.nstat, .running))
        scheduleRefresh()
    }

    /// Counts for long-lived sockets arrive only when asked for; ask every `cadence` seconds.
    private func scheduleRefresh() {
        refreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + cadence, repeating: cadence, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, let manager = self.manager else { return }
            self.api.queryAllSources(manager) {}
        }
        timer.resume()
        refreshTimer = timer
    }

    private func update(_ token: UInt64, _ dict: CFDictionary?) {
        guard let dict = dict as? [String: Any] else { return }
        var state = merged[token] ?? [:]
        state.merge(dict) { _, new in new }
        merged[token] = state
        guard let sample = Self.sample(from: state, keys: api.keys) else {
            requeryIfActive(token, counts: dict)
            return
        }
        if lastYield[token] == sample { return }
        lastYield[token] = sample
        sink?.yield(.upsert(sample, token: token, at: Date()))
    }

    /// The description a socket gets when it is created predates connect(); counts that show
    /// a live TCP state or traffic mean the endpoints are known now.
    private func requeryIfActive(_ token: UInt64, counts: [String: Any]) {
        guard let source = sourceRefs[token] else { return }
        let state = counts[api.keys.tcpState] as? String
        let traffic = ((counts[api.keys.rxBytes] as? NSNumber)?.uint64Value ?? 0)
            + ((counts[api.keys.txBytes] as? NSNumber)?.uint64Value ?? 0)
        let active = (state != nil && state != "Closed") || traffic > 0
        guard active else { return }
        let now = Date()
        if let last = lastRequery[token], now.timeIntervalSince(last) < 1 { return }
        lastRequery[token] = now
        api.queryDescription(source)
    }

    private func remove(_ token: UInt64) {
        sourceRefs.removeValue(forKey: token)
        lastRequery.removeValue(forKey: token)
        merged.removeValue(forKey: token)
        if lastYield.removeValue(forKey: token) != nil {
            sink?.yield(.removed(token: token, at: Date()))
        }
    }

    // MARK: - Decoding

    /// A source description → a sample, or nil while the socket is not yet a connection
    /// (a TCP socket before connect/listen reports 0.0.0.0:0 both ways; an unbound UDP
    /// socket has no port).
    static func sample(from d: [String: Any], keys k: NStatAPI.Keys) -> FlowSample? {
        guard let pid = (d[k.pid] as? NSNumber)?.int32Value,
              let localData = d[k.local] as? Data,
              let local = EndpointFormat.decode(localData)
        else { return nil }
        let remote = (d[k.remote] as? Data).flatMap(EndpointFormat.decode)
        let ipv6 = local.ipv6
        let provider = ((d[k.provider] as? String) ?? "").uppercased()
        let proto: FlowProto
        switch provider {
        case "TCP": proto = ipv6 ? .tcp6 : .tcp4
        case "UDP": proto = ipv6 ? .udp6 : .udp4
        case "QUIC": proto = ipv6 ? .quic6 : .quic4
        default: proto = .other
        }
        let state = proto.isUDP ? "" : ((d[k.tcpState] as? String) ?? "")
        let remoteIsWildcard = remote?.address == nil && remote?.port == nil
        if remoteIsWildcard {
            if proto.isUDP, local.port == nil { return nil }
            if !proto.isUDP, state != "Listen" { return nil }
        }
        var interface = ""
        if let index = (d[k.interface] as? NSNumber)?.uint32Value, index > 0 {
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            if if_indextoname(index, &name) != nil { interface = String(cString: name) }
        }
        let epid = (d[k.epid] as? NSNumber)?.int32Value
        return FlowSample(
            processName: (d[k.processName] as? String) ?? "pid \(pid)",
            pid: pid,
            proto: proto,
            local: EndpointFormat.string(address: local.address, port: local.port, ipv6: ipv6),
            remote: EndpointFormat.string(address: remote?.address, port: remote?.port, ipv6: remote?.ipv6 ?? ipv6),
            interface: interface,
            state: state,
            bytesIn: (d[k.rxBytes] as? NSNumber)?.uint64Value ?? 0,
            bytesOut: (d[k.txBytes] as? NSNumber)?.uint64Value ?? 0,
            origin: .nstat,
            effectivePid: (epid != nil && epid != pid && epid != 0) ? epid : nil
        )
    }
}

/// The NetworkStatistics entry points Pelican uses, resolved at runtime. The signatures match
/// what nettop imports and what Netiquette documents; `swift run Pelican --nstat-probe` prints
/// what the running OS actually delivers.
struct NStatAPI: @unchecked Sendable {
    typealias AddedBlock = @convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias DictBlock = @convention(block) (CFDictionary?) -> Void
    typealias VoidBlock = @convention(block) () -> Void

    typealias CreateFn = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer, @escaping AddedBlock) -> UnsafeMutableRawPointer?
    typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias AddAllFn = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt64) -> Int32
    typealias SetDictBlockFn = @convention(c) (UnsafeMutableRawPointer, @escaping DictBlock) -> Void
    typealias SetVoidBlockFn = @convention(c) (UnsafeMutableRawPointer, @escaping VoidBlock) -> Void
    typealias QueryFn = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias QueryAllFn = @convention(c) (UnsafeMutableRawPointer, @escaping VoidBlock) -> Void

    /// Description dictionary keys. Resolved from the framework's exported kNStatSrcKey*
    /// constants; the literals are the fallback (and what those constants hold today).
    struct Keys {
        var pid = "processID", epid = "epid", processName = "processName"
        var local = "localAddress", remote = "remoteAddress", tcpState = "TCPState"
        var rxBytes = "rxBytes", txBytes = "txBytes", interface = "interface", provider = "provider"
    }

    static let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"

    let create: CreateFn
    let destroy: DestroyFn
    let addAllTCP: AddAllFn
    let addAllUDP: AddAllFn
    let setDescriptionBlock: SetDictBlockFn
    let setCountsBlock: SetDictBlockFn
    let setRemovedBlock: SetVoidBlockFn
    let queryDescription: QueryFn
    let queryAllSources: QueryAllFn
    let keys: Keys

    static func load() -> Result<NStatAPI, NStatFlowSource.LoadError> {
        guard let handle = dlopen(path, RTLD_NOW) else {
            let reason = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            return .failure(.init(reason: reason))
        }
        var missing: [String] = []
        func fn<T>(_ name: String, _ type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { missing.append(name); return nil }
            return unsafeBitCast(symbol, to: type)
        }
        func key(_ name: String, _ fallback: String) -> String {
            guard let symbol = dlsym(handle, name) else { return fallback }
            let value = symbol.assumingMemoryBound(to: Unmanaged<CFString>?.self).pointee
            return value.map { $0.takeUnretainedValue() as String } ?? fallback
        }
        let create = fn("NStatManagerCreate", CreateFn.self)
        let destroy = fn("NStatManagerDestroy", DestroyFn.self)
        let addTCP = fn("NStatManagerAddAllTCPWithFilter", AddAllFn.self)
        let addUDP = fn("NStatManagerAddAllUDPWithFilter", AddAllFn.self)
        let setDescription = fn("NStatSourceSetDescriptionBlock", SetDictBlockFn.self)
        let setCounts = fn("NStatSourceSetCountsBlock", SetDictBlockFn.self)
        let setRemoved = fn("NStatSourceSetRemovedBlock", SetVoidBlockFn.self)
        let queryDescription = fn("NStatSourceQueryDescription", QueryFn.self)
        let queryAll = fn("NStatManagerQueryAllSources", QueryAllFn.self)
        guard missing.isEmpty,
              let create, let destroy, let addTCP, let addUDP, let setDescription,
              let setCounts, let setRemoved, let queryDescription, let queryAll
        else {
            return .failure(.init(reason: "missing symbols: " + missing.joined(separator: ", ")))
        }
        var keys = Keys()
        keys.pid = key("kNStatSrcKeyPID", keys.pid)
        keys.epid = key("kNStatSrcKeyEPID", keys.epid)
        keys.processName = key("kNStatSrcKeyProcessName", keys.processName)
        keys.local = key("kNStatSrcKeyLocal", keys.local)
        keys.remote = key("kNStatSrcKeyRemote", keys.remote)
        keys.tcpState = key("kNStatSrcKeyTCPState", keys.tcpState)
        keys.rxBytes = key("kNStatSrcKeyRxBytes", keys.rxBytes)
        keys.txBytes = key("kNStatSrcKeyTxBytes", keys.txBytes)
        keys.interface = key("kNStatSrcKeyInterface", keys.interface)
        keys.provider = key("kNStatSrcKeyProvider", keys.provider)
        return .success(NStatAPI(
            create: create, destroy: destroy, addAllTCP: addTCP, addAllUDP: addUDP,
            setDescriptionBlock: setDescription, setCountsBlock: setCounts,
            setRemovedBlock: setRemoved, queryDescription: queryDescription,
            queryAllSources: queryAll, keys: keys))
    }
}
