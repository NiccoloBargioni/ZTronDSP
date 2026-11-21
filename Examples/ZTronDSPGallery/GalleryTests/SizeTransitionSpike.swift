import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import Testing
import UIKit
import ZTronDSP
@testable import ZTronDSPUI

extension InApp {
    /// The spike WP-822: how a hosted `MTKView` moves through an animated frame change and a
    /// rotation (SZ-4). Each test applies one stimulus to a component in the application and
    /// writes what the recorder saw into `wp822-corrected-<stimulus>.log` in the
    /// application's Documents folder. What the spike found with the package as it was
    /// built then, and the logs of that, are in
    /// `Examples/ZTronDSPGallery/Spikes/WP-822-findings.md` and under `Spikes/logs/`.
    ///
    /// The package now follows the corrected rule (the findings' closing section), and the
    /// same stimuli are kept as its record in a real application: each test also expects
    /// that no frame of the display was committed with a drawable more than a pixel from the
    /// size its layer was shown at. The cells of §8.9 are asserted by the acceptance WP-824
    /// (`SizeTransitionAcceptanceTests`).
    @MainActor
    @Suite("Spike: size transitions (WP-822)")
    struct SizeTransitionSpike {
        static let small = CGSize(width: 200, height: 120)
        static let large = CGSize(width: 320, height: 300)

        private static func animation(_ curve: String) -> Animation {
            switch curve {
            case "linear": .linear(duration: 0.5)
            case "easeInOut": .easeInOut(duration: 0.5)
            default: .spring(response: 0.5, dampingFraction: 0.6)
            }
        }

        /// Says what a recording amounts to, in the test's output and in a file beside the logs.
        private func summarise(_ stimulus: String, _ record: TransitionRecorder, draws: Int) -> CGFloat {
            // Frames in which Core Animation showed the layer further on at the commit than
            // when the frame was drawn are counted and judged by what the layer said when the
            // frame was drawn (`TransitionRecorder.Frame.layerMovedOn`).
            let movedOn = record.frames.filter(\.layerMovedOn)
            let worst = record.frames.filter { !$0.layerMovedOn }.map(\.committed.mismatch).max() ?? 0
            let whenDrawn = record.frames.map(\.mismatchWhenDrawn).max() ?? 0
            let line = "\(stimulus): frames=\(record.frames.count) draws=\(draws)"
                + String(format: " worstCommitted=%.2f px worstWhenDrawn=%.2f px movedOn=%d (worst %.2f px)", Double(worst), Double(whenDrawn), movedOn.count,
                         Double(movedOn.map(\.committed.mismatch).max() ?? 0))
                + String(format: " commitsWithoutAFrame=%d longest=%.1f ms", record.commitsWithoutAFrame, record.longestWithoutAFrame * 1_000)
            print("ZTD-822 \(line)")
            if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let url = folder.appendingPathComponent("wp822-corrected-summary.log")
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data((line + "\n").utf8))
                } else {
                    try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
                }
            }
            #expect(whenDrawn <= 1, "\(stimulus): every frame was drawn at the size the layer was shown at, within one pixel: \(whenDrawn) px")
            return worst
        }

        /// A `.frame` change inside `withAnimation`: there and back.
        @Test(arguments: ["linear", "easeInOut", "spring"])
        func aFrameAnimatedInsideWithAnimation(curve: String) async throws {
            let bench = try TransitionBench<CGSize>()
            try await bench.open(Self.small, window: CGSize(width: 360, height: 420)) { size, spectrogram, probe in
                spectrogram
                    .sizeTapped(by: probe)
                    .frame(width: size.wrappedValue.width, height: size.wrappedValue.height)
            }
            let record = try bench.record, before = bench.watch.probe.draws
            for target in [Self.large, Self.small] {
                record.note("stimulus withAnimation(\(curve), 0.5 s) frame -> \(TransitionRecorder.text(target))")
                await bench.handle.animate(to: target, Self.animation(curve))
                record.note("stimulus.completed")
                await bench.settle()
            }
            let worst = summarise("frame-\(curve)", record, draws: bench.watch.probe.draws - before)
            bench.close(savingAs: "wp822-corrected-frame-\(curve)")
            #expect(record.frames.count >= 4 && record.lines.contains { $0.contains("probe.") }, "the transition was recorded")
            #expect(worst <= 1, "no frame was committed with a drawable more than a pixel from its layer: \(worst) px")
        }

        /// A `.frame` change without animation, three times: one draw each (§8.4).
        @Test func aFrameChangedWithoutAnimation() async throws {
            let bench = try TransitionBench<CGSize>()
            try await bench.open(Self.small, window: CGSize(width: 360, height: 420)) { size, spectrogram, probe in
                spectrogram
                    .sizeTapped(by: probe)
                    .frame(width: size.wrappedValue.width, height: size.wrappedValue.height)
            }
            let record = try bench.record, before = bench.watch.probe.draws
            let sizes = [Self.large, Self.small, CGSize(width: 260, height: 210)]
            for (index, size) in sizes.enumerated() {
                record.note("stimulus set frame \(TransitionRecorder.text(size))")
                bench.handle.set(size)
                #expect(await eventually { (try? bench.watch.view.bounds.size) == size })
                await bench.settle()
                #expect(bench.watch.probe.draws == before + index + 1, "one draw for \(size): \(bench.watch.probe.draws - before - index)")
            }
            let worst = summarise("frame-plain", record, draws: bench.watch.probe.draws - before)
            bench.close(savingAs: "wp822-corrected-frame-plain")
            #expect(record.frames.count >= 3)
            #expect(worst <= 1, "no frame was committed with a drawable more than a pixel from its layer: \(worst) px")
        }

        /// The component's size changes because the view beside it is animated: the layout
        /// moves it, with no `.frame` of its own.
        @Test func aSizeThatFollowsAnAnimatedNeighbour() async throws {
            let bench = try TransitionBench<CGFloat>()
            try await bench.open(60, window: CGSize(width: 320, height: 400)) { height, spectrogram, probe in
                VStack(spacing: 0) {
                    Color.blue.frame(height: height.wrappedValue)
                    spectrogram.sizeTapped(by: probe)
                }
            }
            let record = try bench.record, before = bench.watch.probe.draws
            record.note("stimulus withAnimation(linear, 0.5 s) neighbour height 60 -> 240")
            await bench.handle.animate(to: 240, .linear(duration: 0.5))
            record.note("stimulus.completed")
            await bench.settle()
            let worst = summarise("neighbour", record, draws: bench.watch.probe.draws - before)
            bench.close(savingAs: "wp822-corrected-neighbour")
            #expect(record.frames.count >= 4)
            #expect(worst <= 1, "no frame was committed with a drawable more than a pixel from its layer: \(worst) px")
        }

        /// The interface turns, there and back: asked of the scene, which animates as it does
        /// when the device is turned. The window fills the scene, and the component fills
        /// the window but for a margin, so that its size follows the scene's.
        @Test func aRotationOfTheInterface() async throws {
            let bench = try TransitionBench<Int>()
            try await bench.open(0, window: nil) { _, spectrogram, probe in
                spectrogram
                    .sizeTapped(by: probe)
                    .padding(40)
            }
            let record = try bench.record, scene = try #require(bench.scene), view = try bench.watch.view
            let portrait = view.bounds.size, before = bench.watch.probe.draws
            // The log is written as it grows: it is there whatever a rotation does to the application.
            record.keepJournal(as: "wp822-corrected-rotation")
            func turn(to name: String, _ mask: UIInterfaceOrientationMask) async {
                record.note("stimulus requestGeometryUpdate \(name)")
                scene.turnInterface(to: mask) { record.note("stimulus.refused \($0)") }
                let wantsLandscape = name != "portrait"
                #expect(await eventually { scene.interfaceOrientation.isLandscape == wantsLandscape }, "the interface turned to \(name)")
                #expect(await eventually { (view.bounds.size != portrait) == wantsLandscape }, "and the component with it")
                await bench.settle()
                await displayFrames(20)
                record.note("stimulus.settled view=\(TransitionRecorder.text(view.bounds.size)) drawable=\(TransitionRecorder.text(view.drawableSize))")
            }
            await turn(to: "landscapeRight", .landscapeRight)
            let turned = view.drawableSize, lying = view.bounds.size
            await turn(to: "portrait", .portrait)
            let worst = summarise("rotation", record, draws: bench.watch.probe.draws - before)
            let scale = record.displayScale
            bench.close(savingAs: "wp822-corrected-rotation")
            #expect(record.frames.count >= 4)
            #expect(worst <= 1, "no frame was committed with a drawable more than a pixel from its layer: \(worst) px")
            #expect(turned == LayerGeometry.pixels(lying, scale: scale), "the drawable had the layer's size on its side: \(turned)")
            #expect(view.drawableSize == LayerGeometry.pixels(portrait, scale: scale), "and has it again upright: \(view.drawableSize)")
        }

        /// When does a layer's presentation value belong to? A layer with a linear animation
        /// of one point per millisecond is a clock: the width it is shown at is the time
        /// Core Animation evaluated the animation at. The log sets that time beside the
        /// display link's own times, on a tick and when the run loop goes to wait.
        @Test func thePresentationClock() async throws {
            let scene = try await AppScene.active()
            let hosted = Hosted(in: scene, size: CGSize(width: 200, height: 100), Color.gray)
            defer { hosted.close() }
            await displayFrames(4)
            let clock = CALayer()
            clock.bounds = CGRect(x: 0, y: 0, width: 0, height: 1)
            hosted.window.layer.addSublayer(clock)
            CATransaction.flush()
            let animation = CABasicAnimation(keyPath: "bounds.size.width")
            animation.fromValue = 0
            animation.toValue = 4_000
            animation.duration = 4
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            let began = CACurrentMediaTime()
            animation.beginTime = clock.convertTime(began, from: nil)
            clock.add(animation, forKey: "clock")

            let lines = Box<[String]>([]), reads = Box(true)
            func shown() -> Double { Double(clock.presentation()?.bounds.size.width ?? -1) / 1_000 }
            let link = CADisplayLink(target: LinkTarget { link in
                let now = CACurrentMediaTime()
                lines.value.append(String(format: "tick now=%.4f timestamp=%.4f target=%.4f shown=%.4f", now - began, link.timestamp - began, link.targetTimestamp - began, shown()))
            }, selector: #selector(LinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            let turns = RunLoopTurns()
            func atEnd() {
                turns.atEndOfTurn {
                    if reads.value { lines.value.append(String(format: "turn.end now=%.4f shown=%.4f", CACurrentMediaTime() - began, shown())) }
                    atEnd()
                }
            }
            atEnd()
            await displayFrames(40)
            // The same without the reading at the end of the turn: does it change what a tick reads?
            reads.value = false
            lines.value.append("no reading at the end of the turn from here on")
            await displayFrames(40)
            link.invalidate()
            turns.stop()
            clock.removeFromSuperlayer()
            if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? (lines.value.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("wp822-presentation-clock.log"), atomically: true, encoding: .utf8)
            }
            #expect(lines.value.count >= 80)
        }
    }
}

/// What a display link calls.
final class LinkTarget: NSObject {
    private let action: @MainActor (CADisplayLink) -> Void

    init(_ action: @escaping @MainActor (CADisplayLink) -> Void) {
        self.action = action
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        action(link)
    }
}
