import Foundation
import Testing
@testable import PelicanKit

// MARK: - A fake machine

/// A scripted set of processes, so the table's behaviour can be tested without the OS.
private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    struct Entry {
        var core: ProcessCore
        var details: ProcessDetails
        var arguments: [String]
        var alive: Bool = true
    }
    private let lock = NSLock()
    private var entries: [Int32: Entry] = [:]

    func add(pid: Int32, born: Double, parent: Int32, name: String,
             path: String? = nil, outer: String? = nil, arguments: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        entries[pid] = Entry(
            core: ProcessCore(stamp: ProcessStamp(pid: pid, startTime: UInt64(born * 1_000_000)),
                              parentPid: parent, groupPid: parent, name: name),
            details: ProcessDetails(executablePath: path, outerBundleID: outer),
            arguments: arguments)
    }

    func kill(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        entries[pid]?.alive = false
    }

    func core(pid: Int32) -> ProcessCore? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[pid], entry.alive else { return nil }
        return entry.core
    }
    func details(pid: Int32) -> ProcessDetails? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[pid], entry.alive else { return nil }
        return entry.details
    }
    func arguments(pid: Int32) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return entries[pid].flatMap { $0.alive ? $0.arguments : nil }
    }
    func children(pid: Int32) -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter { $0.alive && $0.core.parentPid == pid }.map(\.core.stamp.pid)
    }
    func allPids() -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter(\.alive).map(\.core.stamp.pid)
    }
}

/// The chain observed on a Mac running Claude Code in VS Code.
private func claudeCodeMachine() -> FakeInspector {
    let fake = FakeInspector()
    fake.add(pid: 2322, born: 0, parent: 1, name: "Code",
             path: "/Applications/Visual Studio Code.app/Contents/MacOS/Code", outer: "com.microsoft.VSCode")
    fake.add(pid: 15708, born: 10, parent: 2322, name: "Code Helper (Plugin)",
             path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
             outer: "com.microsoft.VSCode")
    fake.add(pid: 16186, born: 20, parent: 15708, name: "claude",
             path: "/x/.vscode/extensions/anthropic.claude-code-2.1.289-darwin-arm64/resources/native-binary/claude")
    fake.add(pid: 70489, born: 30, parent: 16186, name: "zsh", path: "/bin/zsh")
    fake.add(pid: 70521, born: 31, parent: 70489, name: "curl", path: "/usr/bin/curl",
             arguments: ["curl", "-H", "Authorization: Bearer secret-value", "https://example.com"])
    return fake
}

// MARK: - Tests

@Suite struct ProcessTableTests {

    @Test func sightingRecordsTheWholeAncestryAtOnce() throws {
        let fake = claudeCodeMachine()
        let table = ProcessTable(inspector: fake)
        table.sight(pid: 70521, at: Date())
        let lineage = try #require(table.snapshot().lineage(pid: 70521, at: Date()))
        #expect(lineage.nodes.map(\.name) == ["curl", "zsh", "claude", "Code Helper (Plugin)", "Code"])
    }

    @Test func aProcessThatExitsRightAfterIsStillTraceable() throws {
        let fake = claudeCodeMachine()
        let table = ProcessTable(inspector: fake)
        let when = Date()
        table.sight(pid: 70521, at: when)      // the flow's open path
        fake.kill(70521)                       // curl finishes immediately after
        fake.kill(70489)
        let lineage = try #require(table.snapshot().lineage(pid: 70521, at: when))
        #expect(lineage.nodes.map(\.name).prefix(3) == ["curl", "zsh", "claude"])
    }

    @Test func enrichmentFillsPathAndOuterBundle() throws {
        let fake = claudeCodeMachine()
        let table = ProcessTable(inspector: fake)
        table.sight(pid: 15708, at: Date())
        let node = try #require(table.snapshot().incarnation(pid: 15708, at: Date()))
        #expect(node.executablePath?.hasSuffix("Code Helper (Plugin)") == true)
        // The outer app, not the helper's own inner bundle — that is what identifies the tool.
        #expect(node.outerBundleID == "com.microsoft.VSCode")
    }

    @Test func watchingPicksUpChildren() throws {
        let fake = claudeCodeMachine()
        let table = ProcessTable(inspector: fake)
        table.watchDescendants(of: 16186)
        let tree = table.snapshot()
        #expect(tree.incarnation(pid: 16186, at: Date())?.name == "claude")
        #expect(tree.incarnation(pid: 70489, at: Date())?.name == "zsh")
    }

    @Test func argumentsAreRedactedBeforeTheyCanBeShown() throws {
        let fake = claudeCodeMachine()
        let raw = try #require(fake.arguments(pid: 70521))
        let shown = ArgumentRedactor.redact(raw)
        #expect(!shown.joined(separator: " ").contains("secret-value"))
        #expect(shown.contains("https://example.com"))
        // The tree never holds arguments at all.
        let table = ProcessTable(inspector: fake)
        table.sight(pid: 70521, at: Date())
        let node = try #require(table.snapshot().incarnation(pid: 70521, at: Date()))
        #expect(node.name == "curl")
    }
}
