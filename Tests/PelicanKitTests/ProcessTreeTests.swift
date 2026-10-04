import Foundation
import Testing
@testable import PelicanKit

// MARK: - Fixtures

/// Seconds after an arbitrary epoch, as a Date and as a process start time.
private let epoch: Double = 1_700_000_000
private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: epoch + seconds) }
private func stamp(_ pid: Int32, born seconds: Double) -> ProcessStamp {
    ProcessStamp(pid: pid, startTime: UInt64((epoch + seconds) * 1_000_000))
}
private func node(_ stamp: ProcessStamp, _ name: String, parent: ProcessStamp? = nil,
                  path: String? = nil, outer: String? = nil) -> ProcessNode {
    ProcessNode(stamp: stamp, parent: parent, name: name, executablePath: path,
                outerBundleID: outer, firstSeen: stamp.birth)
}

/// The tree observed on a Mac running Claude Code inside VS Code:
/// curl ← zsh ← claude ← Code Helper (Plugin) ← Code ← launchd.
private struct ObservedTree {
    let code = stamp(2322, born: 0)
    let plugin = stamp(15708, born: 10)
    let claude = stamp(16186, born: 20)
    let zsh = stamp(70489, born: 30)
    let curl = stamp(70521, born: 31)

    func build() -> ProcessTree {
        var tree = ProcessTree()
        tree.record(node(code, "Code", parent: ProcessStamp(pid: 1, startTime: 0),
                         path: "/Applications/Visual Studio Code.app/Contents/MacOS/Code",
                         outer: "com.microsoft.VSCode"))
        tree.record(node(plugin, "Code Helper (Plugin)", parent: code,
                         path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                         outer: "com.microsoft.VSCode"))
        tree.record(node(claude, "claude", parent: plugin,
                         path: "~/.vscode/extensions/anthropic.claude-code-2.1.289-darwin-arm64/resources/native-binary/claude"))
        tree.record(node(zsh, "zsh", parent: claude, path: "/bin/zsh"))
        tree.record(node(curl, "curl", parent: zsh, path: "/usr/bin/curl"))
        return tree
    }
}

// MARK: - Tests

@Suite struct ProcessTreeTests {

    @Test func walksTheObservedChainNearestFirst() throws {
        let observed = ObservedTree()
        let lineage = try #require(observed.build().lineage(pid: observed.curl.pid, at: time(32)))
        #expect(lineage.nodes.map(\.name) == ["curl", "zsh", "claude", "Code Helper (Plugin)", "Code"])
        // Stopped at launchd, a real root, so nothing is unknown.
        #expect(lineage.unknownAncestorPid == nil)
        #expect(lineage.nodes.last?.outerBundleID == "com.microsoft.VSCode")
    }

    @Test func parentThatExitedIsStillAnAncestor() throws {
        let observed = ObservedTree()
        var tree = observed.build()
        // The shell finishes before Pelican looks at curl's flow.
        tree.markExited(observed.zsh, at: time(31.5))
        let lineage = try #require(tree.lineage(pid: observed.curl.pid, at: time(32)))
        #expect(lineage.nodes.map(\.name).prefix(3) == ["curl", "zsh", "claude"])
    }

    @Test func reparentingKeepsTheOriginalParent() throws {
        let observed = ObservedTree()
        var tree = observed.build()
        // claude exits; its shell is reparented to launchd and re-reported with no parent.
        tree.markExited(observed.claude, at: time(40))
        tree.record(node(observed.zsh, "zsh", parent: nil, path: "/bin/zsh"))
        let lineage = try #require(tree.lineage(pid: observed.zsh.pid, at: time(41)))
        #expect(lineage.nodes.map(\.name).prefix(2) == ["zsh", "claude"])
    }

    @Test func pidReuseResolvesByTime() throws {
        var tree = ProcessTree()
        let firstShell = stamp(500, born: 0)
        let laterTool = stamp(500, born: 100)          // same pid, a different process later
        tree.record(node(firstShell, "zsh"))
        tree.record(node(laterTool, "python3"))
        #expect(tree.incarnation(pid: 500, at: time(50))?.name == "zsh")
        #expect(tree.incarnation(pid: 500, at: time(150))?.name == "python3")
    }

    @Test func unknownParentStopsTheWalkAndSaysWhere() throws {
        var tree = ProcessTree()
        let orphan = stamp(900, born: 5)
        tree.record(node(orphan, "node", parent: stamp(800, born: 1)))
        let lineage = try #require(tree.lineage(pid: 900, at: time(6)))
        #expect(lineage.nodes.map(\.name) == ["node"])
        #expect(lineage.unknownAncestorPid == 800)
    }

    @Test func exitedProcessesArePrunedAfterTheirTTL() {
        let observed = ObservedTree()
        var tree = observed.build()
        tree.tombstoneTTL = 60
        tree.markExited(observed.curl, at: time(32))
        tree.pruneTombstones(now: time(32 + 30))
        #expect(tree.incarnation(pid: observed.curl.pid, at: time(32)) != nil)
        tree.pruneTombstones(now: time(32 + 61))
        #expect(tree.incarnation(pid: observed.curl.pid, at: time(32)) == nil)
        #expect(tree.count == 4)                       // the live processes stay
    }

    @Test func tombstoneCeilingDropsTheOldestFirst() {
        var tree = ProcessTree()
        tree.maxTombstones = 2
        for i in 0..<4 {
            let s = stamp(Int32(1000 + i), born: Double(i))
            tree.record(node(s, "p\(i)"))
            tree.markExited(s, at: time(Double(10 + i)))
        }
        tree.pruneTombstones(now: time(20))
        #expect(tree.count == 2)
        #expect(tree.incarnation(pid: 1000, at: time(0)) == nil)
        #expect(tree.incarnation(pid: 1003, at: time(3)) != nil)
    }
}
