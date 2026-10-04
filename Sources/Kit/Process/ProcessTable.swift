import Darwin
import Foundation

/// Keeps a live `ProcessTree`, so any flow can be traced to the process that caused it.
///
/// Three inputs feed it, because none alone is enough:
///   • `sight(pid:at:)` — called the moment a flow appears, before any debounce. It walks the
///     ancestry with cheap syscalls on the caller's thread, so a `curl` that lives 50 ms is
///     still traced to the agent that ran it.
///   • a periodic scan — notices processes that never open a socket, and records exits.
///   • fork/exec/exit watching on processes of interest and their descendants.
///
/// State is confined to a serial queue, as the capture sources do.
package final class ProcessTable: @unchecked Sendable {

    private let queue = DispatchQueue(label: "pelican.process.table", qos: .utility)
    private let inspector: any ProcessInspecting
    private var tree = ProcessTree()
    private var watchers: [ProcessStamp: DispatchSourceProcess] = [:]
    private var watched: Set<Int32> = []
    private var timer: DispatchSourceTimer?
    private var lastPrune = Date()

    /// How deep `sight` walks before giving up (a cycle guard; real chains are short).
    package static let maxAncestry = 24
    /// Ceiling on fork watchers, so a runaway process tree can't exhaust them.
    package static let maxWatchers = 512

    package init(inspector: any ProcessInspecting = LiveProcessInspector()) {
        self.inspector = inspector
    }

    // MARK: - Lifecycle

    package func start(scanInterval: TimeInterval = 2) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: scanInterval)
            timer.setEventHandler { [weak self] in self?.scanLocked() }
            timer.resume()
            self.timer = timer
        }
    }

    package func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            for watcher in self.watchers.values { watcher.cancel() }
            self.watchers = [:]
            self.watched = []
        }
    }

    /// A copy of the tree, for attribution off this queue.
    package func snapshot() -> ProcessTree {
        queue.sync { tree }
    }

    // MARK: - Sighting

    /// Record `pid` and its ancestors now, while they are alive. Cheap enough to call from a
    /// flow's open path: one `proc_pidinfo` per generation.
    package func sight(pid: Int32, at time: Date = Date()) {
        var chain: [ProcessCore] = []
        var current = pid
        var seen: Set<Int32> = []
        while current > 1, chain.count < Self.maxAncestry, !seen.contains(current) {
            seen.insert(current)
            guard let core = inspector.core(pid: current) else { break }
            chain.append(core)
            current = core.parentPid
        }
        guard !chain.isEmpty else { return }
        queue.async { self.record(chain: chain, at: time, enrich: true) }
    }

    /// Watch a process and its descendants for forks, so short-lived children are caught even
    /// when they never open a socket of their own.
    package func watchDescendants(of pid: Int32) {
        queue.async {
            guard let core = self.inspector.core(pid: pid) else { return }
            self.record(chain: [core], at: Date(), enrich: true)
            self.watchLocked(core)
            for child in self.inspector.children(pid: pid) {
                guard let childCore = self.inspector.core(pid: child) else { continue }
                self.record(chain: [childCore], at: Date(), enrich: true)
                self.watchLocked(childCore)
            }
        }
    }

    // MARK: - Queue-confined work

    /// Record a chain ordered nearest-first, linking each to its parent's stamp.
    private func record(chain: [ProcessCore], at time: Date, enrich: Bool) {
        var fresh: [ProcessStamp] = []
        for (index, core) in chain.enumerated() {
            let parent = index + 1 < chain.count ? chain[index + 1].stamp : parentStamp(of: core)
            let known = tree.incarnation(pid: core.stamp.pid, at: time)?.stamp == core.stamp
            tree.record(ProcessNode(
                stamp: core.stamp,
                parent: parent,
                group: core.groupPid,
                name: core.name,
                firstSeen: time))
            if !known { fresh.append(core.stamp) }
        }
        guard enrich else { return }
        for stamp in fresh { enrichLocked(stamp) }
    }

    private func parentStamp(of core: ProcessCore) -> ProcessStamp? {
        guard core.parentPid > 1 else { return nil }
        return inspector.core(pid: core.parentPid)?.stamp
    }

    /// Fill in the executable, the outermost app bundle and the responsible process. Costs a
    /// path read and an Info.plist read, so it happens once per incarnation, off the hot path.
    private func enrichLocked(_ stamp: ProcessStamp) {
        guard var node = tree.incarnation(pid: stamp.pid, at: stamp.birth), node.stamp == stamp,
              node.executablePath == nil, let details = inspector.details(pid: stamp.pid) else { return }
        node.executablePath = details.executablePath
        node.outerBundleID = details.outerBundleID
        if let responsible = details.responsiblePid, responsible != stamp.pid {
            node.responsible = inspector.core(pid: responsible)?.stamp
        }
        tree.record(node)
    }

    private func scanLocked() {
        let now = Date()
        var alive: Set<ProcessStamp> = []
        for pid in inspector.allPids() {
            guard let core = inspector.core(pid: pid) else { continue }
            alive.insert(core.stamp)
            if tree.incarnation(pid: pid, at: now)?.stamp != core.stamp {
                record(chain: [core], at: now, enrich: false)
            }
        }
        tree.markExitedExcept(alive, at: now)
        if now.timeIntervalSince(lastPrune) > 60 {
            tree.pruneTombstones(now: now)
            lastPrune = now
        }
    }

    private func watchLocked(_ core: ProcessCore) {
        guard watchers.count < Self.maxWatchers, !watched.contains(core.stamp.pid) else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: core.stamp.pid, eventMask: [.fork, .exec, .exit], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.fork) {
                for child in self.inspector.children(pid: core.stamp.pid) {
                    guard let childCore = self.inspector.core(pid: child) else { continue }
                    self.record(chain: [childCore], at: Date(), enrich: true)
                    self.watchLocked(childCore)
                }
            }
            if events.contains(.exec) {
                var node = self.tree.incarnation(pid: core.stamp.pid, at: Date())
                if node?.stamp == core.stamp {
                    node?.executablePath = nil           // re-read after the image changed
                    if let node { self.tree.record(node) }
                    self.enrichLocked(core.stamp)
                }
            }
            if events.contains(.exit) {
                self.tree.markExited(core.stamp, at: Date())
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            self?.watchers.removeValue(forKey: core.stamp)
            self?.watched.remove(core.stamp.pid)
        }
        watchers[core.stamp] = source
        watched.insert(core.stamp.pid)
        source.resume()
    }
}

extension ProcessTree {
    /// Mark every live process not in `alive` as exited — the scan's way of noticing deaths.
    package mutating func markExitedExcept(_ alive: Set<ProcessStamp>, at time: Date) {
        for stamp in liveStamps where !alive.contains(stamp) {
            markExited(stamp, at: time)
        }
    }
}
