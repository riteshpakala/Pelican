import AppKit
import Darwin
import Foundation

/// Who a pid is, as macOS reports it: executable, enclosing app bundle, parent, start time
/// and code signature.
struct ProcessIdentity: Sendable, Equatable, Codable, Identifiable {
    var pid: Int32
    /// Microseconds since 1970 — with the pid, this survives pid reuse.
    var startTime: UInt64
    var parentPid: Int32?
    var name: String
    var executablePath: String?
    /// The nearest enclosing .app, if any.
    var bundlePath: String?
    var bundleIdentifier: String?
    var bundleVersion: String?
    var bundleBuild: String?
    var launchedAt: Date?
    var signature: CodeSignature?

    var id: String { "\(pid)-\(startTime)" }

    var isDevelopmentBuild: Bool { signature?.isDevelopmentBuild ?? true }

    /// Bundle Info.plist usage descriptions (NS…UsageDescription) — what the app declares it
    /// asks the user for. Read fresh from disk, never cached.
    static func declaredUsage(bundlePath: String) -> [String: String] {
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: url) as? [String: Any] else { return [:] }
        var usage: [String: String] = [:]
        for (key, value) in info where key.hasPrefix("NS") && key.hasSuffix("UsageDescription") {
            if let text = value as? String { usage[key] = text }
        }
        return usage
    }

    static func bundleInfo(bundlePath: String) -> [String: Any]? {
        NSDictionary(contentsOf: URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    // MARK: - Reading

    struct BSDInfo: Sendable { let parentPid: Int32; let startTime: UInt64; let name: String }

    /// Cheap: one syscall. nil when the process is gone.
    static func bsdInfo(pid: Int32) -> BSDInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        let name = withUnsafeBytes(of: info.pbi_name) { raw -> String in
            let text = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return text
        }
        let comm = withUnsafeBytes(of: info.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return BSDInfo(parentPid: Int32(info.pbi_ppid), startTime: start, name: name.isEmpty ? comm : name)
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Full read, including the signature check. Blocking; call off the main thread.
    static func read(pid: Int32) -> ProcessIdentity? {
        guard let bsd = bsdInfo(pid: pid) else { return nil }
        let path = executablePath(pid: pid)
        let bundlePath = path.flatMap(enclosingApp)
        let info = bundlePath.flatMap(bundleInfo)
        let name = path.map { ($0 as NSString).lastPathComponent } ?? bsd.name
        return ProcessIdentity(
            pid: pid,
            startTime: bsd.startTime,
            parentPid: bsd.parentPid > 0 ? bsd.parentPid : nil,
            name: name,
            executablePath: path,
            bundlePath: bundlePath,
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            bundleVersion: info?["CFBundleShortVersionString"] as? String,
            bundleBuild: info?["CFBundleVersion"] as? String,
            launchedAt: Date(timeIntervalSince1970: Double(bsd.startTime) / 1_000_000),
            signature: CodeSignature.read(pid: pid)
        )
    }

    /// "/Applications/Ambient.app/Contents/Helpers/thread" → "/Applications/Ambient.app"
    static func enclosingApp(of path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return url.path }
        }
        return nil
    }

    /// Every running pid whose name (executable basename, or the kernel's short name) is in
    /// `names`.
    static func pids(named names: Set<String>) -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        var out: [Int32] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            if let path = executablePath(pid: pid), names.contains((path as NSString).lastPathComponent) {
                out.append(pid)
            } else if let bsd = bsdInfo(pid: pid), names.contains(bsd.name) {
                out.append(pid)
            }
        }
        return out
    }
}

/// Caches identities by pid + start time. The signature is re-checked after `maxAge`, so a
/// binary modified on disk while running is noticed.
actor ProcessIdentityCache {
    private var cache: [Int32: (identity: ProcessIdentity, readAt: Date)] = [:]
    static let maxAge: TimeInterval = 60

    func identity(for pid: Int32) async -> ProcessIdentity? {
        guard let bsd = ProcessIdentity.bsdInfo(pid: pid) else {
            cache.removeValue(forKey: pid)
            return nil
        }
        if let cached = cache[pid], cached.identity.startTime == bsd.startTime,
           Date().timeIntervalSince(cached.readAt) < Self.maxAge {
            return cached.identity
        }
        let identity = await Task.detached(priority: .utility) { ProcessIdentity.read(pid: pid) }.value
        if let identity { cache[pid] = (identity, Date()) } else { cache.removeValue(forKey: pid) }
        return identity
    }

    func identities(for pids: [Int32]) async -> [Int32: ProcessIdentity] {
        var out: [Int32: ProcessIdentity] = [:]
        for pid in pids {
            if let identity = await identity(for: pid) { out[pid] = identity }
        }
        return out
    }

    /// Running processes whose names are in `names`, with identities.
    func scan(names: Set<String>) async -> [ProcessIdentity] {
        let pids = await Task.detached(priority: .utility) { ProcessIdentity.pids(named: names) }.value
        return Array(await identities(for: pids).values).sorted { $0.pid < $1.pid }
    }

    func isAlive(pid: Int32, startTime: UInt64) -> Bool {
        ProcessIdentity.bsdInfo(pid: pid)?.startTime == startTime
    }
}
