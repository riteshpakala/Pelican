import Foundation

/// A specific run of a process: its pid together with the time it started. The OS reuses pids,
/// but not with the same start time, so a stamp survives reuse where a bare pid does not.
package struct ProcessStamp: Hashable, Sendable, Codable {
    package let pid: Int32
    /// Microseconds since 1970, as `proc_pidinfo` reports it.
    package let startTime: UInt64

    package init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }

    /// When this process began.
    package var birth: Date { Date(timeIntervalSince1970: Double(startTime) / 1_000_000) }
}

/// What the tree knows about one process incarnation. Command-line arguments are deliberately
/// absent: they can hold secrets, so they are matched in memory by the inspector and never kept.
package struct ProcessNode: Sendable, Equatable {
    package let stamp: ProcessStamp
    /// The parent as first seen. Never rewritten, so a later reparent to launchd (ppid 1)
    /// doesn't erase the real ancestry.
    package var parent: ProcessStamp?
    /// Process group leader's pid, for orphans whose parent is gone.
    package var group: Int32?
    /// The process macOS holds responsible (an app for its helpers), when known.
    package var responsible: ProcessStamp?
    package var name: String
    package var executablePath: String?
    /// Bundle identifier of the outermost enclosing `.app`, if any (an Electron helper's outer
    /// app, not its own inner `.app`).
    package var outerBundleID: String?
    package var firstSeen: Date
    package var exitedAt: Date?

    package var pid: Int32 { stamp.pid }

    package init(
        stamp: ProcessStamp, parent: ProcessStamp? = nil, group: Int32? = nil,
        responsible: ProcessStamp? = nil, name: String, executablePath: String? = nil,
        outerBundleID: String? = nil, firstSeen: Date, exitedAt: Date? = nil
    ) {
        self.stamp = stamp
        self.parent = parent
        self.group = group
        self.responsible = responsible
        self.name = name
        self.executablePath = executablePath
        self.outerBundleID = outerBundleID
        self.firstSeen = firstSeen
        self.exitedAt = exitedAt
    }
}

/// A resolved ancestry chain for a flow, nearest process first.
package struct Lineage: Sendable, Equatable {
    /// `[self, parent, grandparent, …]`, as far as the tree knows.
    package var nodes: [ProcessNode]
    /// The pid of the first ancestor the tree had no node for (launchd, or a parent that
    /// exited before Pelican saw it), when the walk stopped before reaching a root.
    package var unknownAncestorPid: Int32?

    package init(nodes: [ProcessNode], unknownAncestorPid: Int32? = nil) {
        self.nodes = nodes
        self.unknownAncestorPid = unknownAncestorPid
    }

    package var leaf: ProcessNode? { nodes.first }
}

/// Remembers process ancestry so a flow can be traced to the tool that ultimately caused it,
/// even after the process that opened it has exited. Pure: the live reads are the inspector's
/// and the table's job. Pid reuse is handled by stamping every incarnation with its start time.
package struct ProcessTree: Sendable {
    private var nodes: [ProcessStamp: ProcessNode] = [:]
    /// Incarnations of each pid, oldest first.
    private var byPid: [Int32: [ProcessStamp]] = [:]

    /// How long an exited process is kept so a flow that closed just after it can still be
    /// traced.
    package var tombstoneTTL: TimeInterval = 600
    /// Ceiling on retained exited processes.
    package var maxTombstones: Int = 4096
    /// A flow's open time can land slightly before the OS reports the opening process's start;
    /// allow this much slack when matching an incarnation to a time.
    package var birthSlack: TimeInterval = 1

    package init() {}

    package var count: Int { nodes.count }

    /// Stamps of every process not yet known to have exited.
    package var liveStamps: [ProcessStamp] {
        nodes.values.filter { $0.exitedAt == nil }.map(\.stamp)
    }

    /// Record a process, or refresh a known one (keeping its original `parent` and `firstSeen`).
    package mutating func record(_ node: ProcessNode) {
        if var existing = nodes[node.stamp] {
            existing.group = node.group ?? existing.group
            existing.responsible = node.responsible ?? existing.responsible
            existing.name = node.name
            existing.executablePath = node.executablePath ?? existing.executablePath
            existing.outerBundleID = node.outerBundleID ?? existing.outerBundleID
            if existing.parent == nil { existing.parent = node.parent }
            if node.exitedAt != nil { existing.exitedAt = node.exitedAt }
            nodes[node.stamp] = existing
            return
        }
        nodes[node.stamp] = node
        byPid[node.stamp.pid, default: []].append(node.stamp)
        // Keep incarnations ordered by start, so `incarnation(pid:at:)` can scan newest first.
        byPid[node.stamp.pid]?.sort { $0.startTime < $1.startTime }
    }

    package mutating func markExited(_ stamp: ProcessStamp, at: Date) {
        guard var node = nodes[stamp] else { return }
        if node.exitedAt == nil { node.exitedAt = at }
        nodes[stamp] = node
    }

    /// The incarnation of `pid` that was alive at `time`: the newest one born at or before it.
    package func incarnation(pid: Int32, at time: Date) -> ProcessNode? {
        guard let stamps = byPid[pid] else { return nil }
        let cutoff = time.addingTimeInterval(birthSlack)
        // Newest-first: the first incarnation born by `time` is the one that owned it.
        for stamp in stamps.reversed() where stamp.birth <= cutoff {
            return nodes[stamp]
        }
        // All known incarnations were born after `time` (we started watching late); the oldest
        // is the best guess.
        return stamps.first.flatMap { nodes[$0] }
    }

    /// Walk ancestors from the incarnation of `pid` alive at `time`, nearest first.
    package func lineage(pid: Int32, at time: Date) -> Lineage? {
        guard let start = incarnation(pid: pid, at: time) else { return nil }
        var chain: [ProcessNode] = [start]
        var visited: Set<ProcessStamp> = [start.stamp]
        var current = start
        while let parentStamp = current.parent {
            if parentStamp.pid <= 1 { break }           // launchd: a real root
            guard !visited.contains(parentStamp), let parent = nodes[parentStamp] else {
                return Lineage(nodes: chain, unknownAncestorPid: parentStamp.pid)
            }
            chain.append(parent)
            visited.insert(parentStamp)
            current = parent
            if chain.count >= 64 { break }              // cycle guard
        }
        return Lineage(nodes: chain)
    }

    /// Drop exited processes past their TTL, and the oldest beyond the tombstone ceiling.
    package mutating func pruneTombstones(now: Date) {
        for (stamp, node) in nodes {
            if let exited = node.exitedAt, now.timeIntervalSince(exited) > tombstoneTTL {
                remove(stamp)
            }
        }
        let exited = nodes.values.filter { $0.exitedAt != nil }
        if exited.count > maxTombstones {
            let doomed = exited.sorted { ($0.exitedAt ?? .distantPast) < ($1.exitedAt ?? .distantPast) }
                .prefix(exited.count - maxTombstones)
            for node in doomed { remove(node.stamp) }
        }
    }

    private mutating func remove(_ stamp: ProcessStamp) {
        nodes.removeValue(forKey: stamp)
        byPid[stamp.pid]?.removeAll { $0 == stamp }
        if byPid[stamp.pid]?.isEmpty == true { byPid.removeValue(forKey: stamp.pid) }
    }
}
