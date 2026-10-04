import Foundation
import Testing
@testable import PelicanKit

private actor Tally {
    var running = 0
    var peak = 0
    var order: [Int] = []
    func enter(_ id: Int) { running += 1; peak = max(peak, running); order.append(id) }
    func leave() { running -= 1 }
}

@Suite struct ModelGateTests {

    @Test func generationsNeverOverlap() async {
        let gate = ModelGate()
        let tally = Tally()
        await withTaskGroup(of: Void.self) { group in
            for id in 0..<8 {
                group.addTask {
                    await gate.run {
                        await tally.enter(id)
                        try? await Task.sleep(for: .milliseconds(5))
                        await tally.leave()
                    }
                }
            }
        }
        #expect(await tally.peak == 1)
        #expect(await tally.order.count == 8)
    }

    @Test func aFailingTurnStillReleasesTheModel() async {
        struct Boom: Error {}
        let gate = ModelGate()
        do {
            try await gate.run { throw Boom() }
        } catch {}
        // If the failed turn had kept the model, this would wait forever.
        let value = await gate.run { 42 }
        #expect(value == 42)
    }
}
