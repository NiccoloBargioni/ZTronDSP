import Foundation
import SwiftUI
import Testing
import UIKit
import ZTronDSP
@testable import ZTronDSPCore
@testable import ZTronDSPUI

/// Collects the samples a pipeline hands its sink: what the main line carries after the stage
/// under test.
final class SampleCollector: FeatureSink, @unchecked Sendable {
    typealias Domain = Samples
    // Threading: the analysis thread appends, the test reads; both behind the lock.
    private let lock = NSLock()
    private var collected: [Float] = []

    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {}
    func release() {}

    func write(_ frame: FrameView) {
        guard let block = frame.samples else { return }
        let samples = block.channel(0)
        lock.withLock {
            var index = 0
            while index < block.frameCount {
                collected.append(samples[index])
                index += 1
            }
        }
    }

    var count: Int { lock.withLock { collected.count } }
    var samples: [Float] { lock.withLock { collected } }
}

extension InApp {
    /// WP-811 (R-25): the hosted activation test. A `Toggle` over `@State`, bound to a stage's
    /// `isActive:`, bypasses and restores the stage within one turn of the run loop and one
    /// block, and the session does not cause the body of the view that owns the state to be
    /// evaluated.
    ///
    /// The view is hosted in the application. The switch is flipped through the control
    /// itself: the `UISwitch` behind the `Toggle` is sent the action a finger sends it, so
    /// the write to the state takes the way a tap's write takes.
    @MainActor
    @Suite("Activation, hosted (WP-811)")
    struct ActivationTests {
        static let blockSize = 64
        /// The gain of the stage under test: what it makes of a sample of 1.
        static let factor: Float = 0.5

        /// The view that owns the state, as the example of §5.9 has it: a toggle, and the
        /// pipeline whose stage the toggle switches.
        struct Controls: View {
            let source: HandFedSource
            let sink: SampleCollector
            /// Times the body was evaluated.
            let evaluations: Box<Int>
            @State private var isOn = true

            var body: some View {
                let _ = evaluations.value += 1
                Toggle("Gain", isOn: $isOn)
                    .padding()
                    .pipeline(Pipeline { Gain(.linear(Double(ActivationTests.factor)), isActive: $isOn); Emit(to: sink) }, on: source)
            }
        }

        private func uiSwitch(in view: UIView) -> UISwitch? {
            if let found = view as? UISwitch { return found }
            for child in view.subviews {
                if let found = uiSwitch(in: child) { return found }
            }
            return nil
        }

        @Test func aToggleOverStateBypassesAndRestoresAStageWithinOneRunLoopTurnAndOneBlock() async throws {
            let scene = try await AppScene.active()
            let engine = DSPEngine(blockSize: Self.blockSize), source = HandFedSource(), sink = SampleCollector()
            let evaluations = Box(0), hosts = PipelineHostProbe()
            let hosted = Hosted(in: scene, Controls(source: source, sink: sink, evaluations: evaluations)
                .dspEngine(engine)
                .environment(\.dspPipelineHostProbe, hosts))
            defer { hosted.close() }
            #expect(await eventually { hosts.attaches == 1 && hosts.session?.state == .running }, "the view attached and started its pipeline: \(hosts.failures)")
            let session = try #require(hosts.session)
            let pump = session.core.pump
            #expect(await eventually { pump.isObserving }, "one observer on the main run loop while the session runs with a bound switch")
            let control = try #require(uiSwitch(in: hosted.window), "the Toggle is a UISwitch")
            #expect(control.isOn)

            let ones = [Float](repeating: 1, count: Self.blockSize)
            /// Writes `blocks` blocks of ones and waits until the sink has them.
            func feed(_ blocks: Int) async {
                let wanted = sink.count + blocks * Self.blockSize
                for _ in 0 ..< blocks { #expect(source.write(ones) == ones.count) }
                #expect(await eventually { sink.count >= wanted }, "the blocks came out: \(sink.count) of \(wanted)")
            }

            // The stage runs: a sample of 1 leaves as 0.5.
            await feed(20)
            #expect(sink.samples.suffix(Self.blockSize).allSatisfy { $0 == Self.factor }, "the gain is applied")
            let evaluated = evaluations.value
            #expect(evaluated >= 1)

            // The session runs and blocks flow, and the main run loop turns: the body of the
            // view that owns the state is not evaluated.
            let passes = pump.passes
            await feed(200)
            await displayFrames(30)
            #expect(pump.passes > passes, "the pump read the switch \(pump.passes - passes) times meanwhile")
            #expect(evaluations.value == evaluated, "the session does not cause the owning view's body to be evaluated")

            let turns = RunLoopTurns()
            defer { turns.stop() }

            /// Flips the toggle as a tap does, and writes one block when the turn of the run
            /// loop in which the state was written ends. Returns how many switch commands the
            /// session had sent by then, and the samples of that one block as they came out.
            func flip(to on: Bool) async throws -> (sent: Int, block: [Float]) {
                let before = sink.count
                let sentAtEndOfTurn = Box<Int?>(nil)
                turns.atEndOfTurn {
                    sentAtEndOfTurn.value = pump.commandsSent
                    // One block, written before the run loop turns again.
                    _ = source.write(ones)
                }
                control.setOn(on, animated: false)
                control.sendActions(for: .valueChanged)
                #expect(await eventually { sink.count >= before + Self.blockSize }, "the block came out")
                let sent = try #require(sentAtEndOfTurn.value, "the turn ended")
                return (sent, Array(sink.samples[before ..< before + Self.blockSize]))
            }

            // Off: the write is forwarded in the turn it is made in, and the block that
            // follows is already on its way to the unprocessed signal.
            var sent = pump.commandsSent
            let off = try await flip(to: false)
            #expect(off.sent == sent + 1, "the switch was forwarded within the run-loop turn of the write (BIND-2): \(off.sent - sent) commands")
            #expect(off.block.first == Self.factor || (off.block.first ?? 0) > Self.factor, "the fade starts at the block boundary: \(off.block.prefix(4))")
            #expect((off.block.last ?? 0) > Self.factor && (off.block.last ?? 2) < 1, "within one block the stage is fading out: the block ends at \(off.block.last ?? -1)")
            #expect(zip(off.block, off.block.dropFirst()).allSatisfy { $0 <= $1 }, "a cross-fade, no click (ACT-7)")
            // After the fade, 10 ms, the stage is bypassed: the signal passes unchanged.
            await feed(12)
            #expect(sink.samples.suffix(Self.blockSize).allSatisfy { $0 == 1 }, "bypassed")
            #expect(pump.commandsSent == sent + 1, "one command for one flip")

            // On again: forwarded in the same turn, and within one block the stage is on its way back.
            sent = pump.commandsSent
            let on = try await flip(to: true)
            #expect(on.sent == sent + 1, "the switch was forwarded within the run-loop turn of the write: \(on.sent - sent) commands")
            #expect((on.block.last ?? 2) < 1 && (on.block.last ?? 0) > Self.factor, "within one block the stage is fading in: the block ends at \(on.block.last ?? -1)")
            #expect(zip(on.block, on.block.dropFirst()).allSatisfy { $0 >= $1 }, "a cross-fade, no click (ACT-7)")
            await feed(12)
            #expect(sink.samples.suffix(Self.blockSize).allSatisfy { $0 == Self.factor }, "restored")

            // Flipping a switch compiles nothing and attaches nothing (ACT-5), and the session
            // never writes a switch (BIND-5).
            #expect(hosts.updates.isEmpty && hosts.attaches == 1 && hosts.detaches == 0 && hosts.failures.isEmpty)
            #expect(control.isOn, "the switch is where the last flip left it")
            // Two flips are at most two evaluations of the owning view, and they are the
            // toggle's doing: none came from the session, which ran all the while.
            #expect(evaluations.value <= evaluated + 2, "\(evaluations.value - evaluated) evaluations for two flips")
            let afterFlips = evaluations.value
            await feed(200)
            await displayFrames(30)
            #expect(evaluations.value == afterFlips, "and blocks that flow afterwards cause none")
        }
    }
}
