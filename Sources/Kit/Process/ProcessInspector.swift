import Darwin
import Foundation

/// The cheap facts about a process: one `proc_pidinfo` call.
package struct ProcessCore: Sendable, Equatable {
    package var stamp: ProcessStamp
    package var parentPid: Int32
    package var groupPid: Int32
    package var name: String

    package init(stamp: ProcessStamp, parentPid: Int32, groupPid: Int32, name: String) {
        self.stamp = stamp
        self.parentPid = parentPid
        self.groupPid = groupPid
        self.name = name
    }
}

/// The costlier facts: the executable, the outermost app bundle around it, and the process
/// macOS holds responsible.
package struct ProcessDetails: Sendable, Equatable {
    package var executablePath: String?
    package var outerBundleID: String?
    package var responsiblePid: Int32?

    package init(executablePath: String? = nil, outerBundleID: String? = nil, responsiblePid: Int32? = nil) {
        self.executablePath = executablePath
        self.outerBundleID = outerBundleID
        self.responsiblePid = responsiblePid
    }
}

/// Reads live process facts. A protocol so the table and its tests can run against a fake.
package protocol ProcessInspecting: Sendable {
    func core(pid: Int32) -> ProcessCore?
    func details(pid: Int32) -> ProcessDetails?
    /// Command-line arguments (argv only, never the environment). For matching in memory; the
    /// caller must not store them.
    func arguments(pid: Int32) -> [String]?
    func children(pid: Int32) -> [Int32]
    func allPids() -> [Int32]
}

/// The real inspector, over Darwin's process APIs.
package struct LiveProcessInspector: ProcessInspecting {
    package init() {}

    package func core(pid: Int32) -> ProcessCore? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        let name = withUnsafeBytes(of: info.pbi_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let comm = withUnsafeBytes(of: info.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessCore(
            stamp: ProcessStamp(pid: pid, startTime: start),
            parentPid: Int32(info.pbi_ppid),
            groupPid: Int32(info.pbi_pgid),
            name: name.isEmpty ? comm : name)
    }

    package func details(pid: Int32) -> ProcessDetails? {
        let path = ProcessIdentity.executablePath(pid: pid)
        let outerBundle = path.flatMap { Self.outermostApp(of: $0) }
            .flatMap { ProcessIdentity.bundleInfo(bundlePath: $0)?["CFBundleIdentifier"] as? String }
        return ProcessDetails(
            executablePath: path,
            outerBundleID: outerBundle,
            responsiblePid: Self.responsiblePid(of: pid))
    }

    package func arguments(pid: Int32) -> [String]? { Self.processArguments(pid: pid) }

    package func children(pid: Int32) -> [Int32] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let filled = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    package func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    // MARK: - Outermost app

    /// The *leftmost* `.app` component of a path — an Electron helper's outer app, not its own
    /// inner `.app`. "/Applications/Cursor.app/…/Cursor Helper.app/…" → "/Applications/Cursor.app".
    /// (`ProcessIdentity.enclosingApp` returns the nearest one instead.)
    package static func outermostApp(of path: String) -> String? {
        let parts = path.components(separatedBy: "/")
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts[...index].joined(separator: "/")
    }

    // MARK: - Responsible process

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil  // RTLD_DEFAULT
        }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    package static func responsiblePid(of pid: Int32) -> Int32? {
        guard let fn = responsibleFn else { return nil }
        let responsible = fn(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }

    // MARK: - Arguments

    /// argv via `sysctl KERN_PROCARGS2`. The buffer is `argc`, the exec path, padding, then the
    /// argv strings, then the environment — which we stop before and never read.
    package static func processArguments(pid: Int32) -> [String]? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var nameMax = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&nameMax, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(argmax))
        var length = Int(argmax)
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, &buffer, &length, nil, 0) == 0, length >= MemoryLayout<Int32>.size else {
            return nil
        }

        return buffer.withUnsafeBytes { raw -> [String]? in
            let base = raw.baseAddress!
            let argc = base.loadUnaligned(as: Int32.self)
            guard argc >= 0 else { return nil }
            var offset = MemoryLayout<Int32>.size
            let bytes = raw.bindMemory(to: UInt8.self)

            func readCString() -> String {
                let start = offset
                while offset < length && bytes[offset] != 0 { offset += 1 }
                let string = String(decoding: bytes[start..<offset], as: UTF8.self)
                offset += 1  // skip the NUL
                return string
            }

            _ = readCString()                       // the exec path
            while offset < length && bytes[offset] == 0 { offset += 1 }  // padding

            var args: [String] = []
            var remaining = Int(argc)
            while remaining > 0 && offset < length {
                args.append(readCString())
                remaining -= 1
            }
            return args
        }
    }
}
