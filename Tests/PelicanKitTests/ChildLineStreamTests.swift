import Darwin
import Foundation
import Testing
@testable import PelicanKit

@Suite struct LineSplitterTests {

    @Test func joinsALineSplitAcrossReadsAndKeepsTheLastOne() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Array("one\ntw".utf8)).lines == ["one"])
        #expect(splitter.feed(Array("o\nthr".utf8)).lines == ["two"])
        #expect(splitter.finish() == ["thr"])
        #expect(splitter.finish().isEmpty)
    }

    @Test func keepsEmptyLines() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Array("a\n\nb\n".utf8)).lines == ["a", "", "b"])
    }

    @Test func dropsARunawayLineWholeAndCountsIt() {
        var splitter = LineSplitter(maxLineLength: 8)
        let first = splitter.feed(Array("short\n0123456789".utf8))
        #expect(first.lines == ["short"])
        #expect(first.oversized == 1)
        // The rest of the runaway line is dropped too, not handed back as a fragment.
        let second = splitter.feed(Array("abcdef\nnext\n".utf8))
        #expect(second.lines == ["next"])
        #expect(second.oversized == 0)
    }

    @Test func aRunawayLastLineIsNotReturnedAtTheEnd() {
        var splitter = LineSplitter(maxLineLength: 4)
        _ = splitter.feed(Array("toolong".utf8))
        #expect(splitter.finish().isEmpty)
    }
}

@Suite struct ChildLineStreamTests {

    /// Collect events until `done` says so, or give up after `seconds`.
    private func collect(_ child: ChildLineStream, seconds: Double = 5,
                         until done: @escaping ([ChildLineStream.Event]) -> Bool) async -> [ChildLineStream.Event] {
        let (stream, sink) = AsyncStream.makeStream(of: ChildLineStream.Event.self)
        child.start(into: sink)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(seconds))
            sink.finish()
        }
        var events: [ChildLineStream.Event] = []
        for await event in stream {
            events.append(event)
            if done(events) { break }
        }
        timeout.cancel()
        return events
    }

    private func lines(_ events: [ChildLineStream.Event]) -> [String] {
        events.flatMap { event -> [String] in
            if case .lines(let lines, _) = event { return lines }
            return []
        }
    }

    @Test func deliversEveryLineThenSaysWhyItStopped() async {
        let child = ChildLineStream(
            command: .init("/bin/sh", ["-c", "printf 'one\\ntwo\\nthree'; echo 'went wrong' >&2; exit 3"]),
            label: "test.exit", restart: nil)
        let events = await collect(child) { events in
            events.contains { if case .exited = $0 { return true }; return false }
        }
        #expect(lines(events) == ["one", "two", "three"])
        let exit = events.compactMap { event -> (Int32, String)? in
            if case .exited(let status, let stderr, _) = event { return (status, stderr) }
            return nil
        }.first
        #expect(exit?.0 == 3)
        #expect(exit?.1 == "went wrong")
    }

    @Test func startsAgainAfterExitingOnItsOwn() async {
        let child = ChildLineStream(
            command: .init("/bin/sh", ["-c", "echo up; exit 1"]), label: "test.restart",
            restart: .init(initial: 0.05, maximum: 0.1, healthyAfter: 10))
        let events = await collect(child) { events in
            events.filter { if case .started = $0 { return true }; return false }.count >= 2
                && lines(events).count >= 2
        }
        child.stopNow()
        #expect(lines(events).prefix(2) == ["up", "up"])
    }

    @Test func saysWhenTheCommandCannotRun() async {
        let child = ChildLineStream(command: .init("/nonexistent/tool", []), label: "test.missing", restart: nil)
        let events = await collect(child) { events in
            events.contains { if case .failedToStart = $0 { return true }; return false }
        }
        #expect(events.contains { if case .failedToStart = $0 { return true }; return false })
    }

    @Test func stoppingEndsTheChildQuietly() async throws {
        let child = ChildLineStream(
            command: .init("/bin/sh", ["-c", "echo ready; exec /bin/sleep 30"]), label: "test.stop")
        let (stream, sink) = AsyncStream.makeStream(of: ChildLineStream.Event.self)
        child.start(into: sink)
        var pid: Int32?
        var iterator = stream.makeAsyncIterator()
        while let event = await iterator.next() {
            if case .started(let started, _) = event { pid = started }
            if case .lines(let lines, _) = event, lines.contains("ready") { break }
        }
        let running = try #require(pid)
        child.stopNow()

        // The child is gone within a moment (once reaped, signalling it fails)…
        var gone = false
        for _ in 0..<40 {
            if kill(running, 0) != 0 { gone = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(gone)
        // …and a requested stop is not reported as an unexpected exit, nor restarted.
        sink.finish()
        var after: [ChildLineStream.Event] = []
        while let event = await iterator.next() { after.append(event) }
        #expect(!after.contains { if case .exited = $0 { return true }; return false })
        #expect(!after.contains { if case .started = $0 { return true }; return false })
    }
}
