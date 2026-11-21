import CoreGraphics
import Foundation
import MetalKit
import SwiftUI
import Testing
import UIKit
import ZTronDSP
import ZTronDSPMetal
@testable import ZTronDSPUI

extension InApp {
    /// WP-824: the size-transition acceptance of §8.9, hosted in the application, for a
    /// half-second animated change from 200 × 120 to 320 × 300 points and for a rotation of
    /// the interface, there and back:
    ///
    /// - at every display tick of the transition, when the frame's transaction is committed,
    ///   the drawable's size equals the presentation size within one pixel;
    /// - a frame captured at the midpoint matches the same content rendered directly at that
    ///   size with PSNR ≥ 35 dB;
    /// - the number of draws is at least the number of ticks minus one;
    /// - nothing is uploaded.
    ///
    /// "At every display tick" is judged where it counts: when the run loop goes to wait at
    /// the end of a frame of the display and the transaction is about to be committed, which
    /// is the moment the layer's bounds and the drawable that was presented with them go to
    /// the display together. For a layer that Core Animation animates there is one thing a
    /// surface cannot do: Core Animation may show the layer further on at the commit than it
    /// said when the frame was made a moment before (`TransitionRecorder.Frame.layerMovedOn`).
    /// Such frames are judged by what the layer said when the frame was made, and counted.
    ///
    /// The package is judged as it is built. Before the corrections that the spike WP-822
    /// called for (`Spikes/WP-822-findings.md`, closing section) it did not meet this
    /// acceptance: the drawable was a step of the animation late in every frame, and in a
    /// rotation it collapsed to a pixel and grew until Metal ended the application.
    @MainActor
    @Suite("Size-transition acceptance, hosted (WP-824)")
    struct SizeTransitionAcceptanceTests {
        static let small = CGSize(width: 200, height: 120)
        static let large = CGSize(width: 320, height: 300)

        /// What a recorded transition is judged by.
        struct Verdict: CustomStringConvertible {
            /// Frames of the display, from the first in which something moved to the last.
            var frames = 0
            /// Frames drawn in them.
            var draws = 0
            var uploads = 0
            /// The largest distance, in pixels, between the drawable and the size the layer is
            /// shown at when a frame of the display is committed, and the frame it was seen in,
            /// counted from the first frame of the transition. Frames in which the layer moved
            /// on between the draw and the commit are left out and counted by themselves.
            var worstCommitted: CGFloat = 0
            var worstFrame = 0
            /// The same when the surface drew its frame, over every frame: what the rule that
            /// sizes the drawable made of each turn.
            var worstWhenDrawn: CGFloat = 0
            /// Frames in which Core Animation showed the layer further on at the commit than
            /// when the frame was drawn (`TransitionRecorder.Frame.layerMovedOn`), and the
            /// largest distance at commit among them.
            var movedOnFrames = 0
            var worstMovedOn: CGFloat = 0
            /// The size of the frame captured at the midpoint, in pixels.
            var captured: CGSize?
            /// The size the layer was shown at when that frame was committed, in pixels.
            var shownAtCapture: CGSize?
            /// That frame, stretched to the size it was shown at as the display stretches it,
            /// against the same content rendered directly at that size.
            var psnr: Double?
            /// After the transition: the drawable, and how far it is from the layer's size.
            var finalDrawable = CGSize.zero
            var finalMismatch: CGFloat = 0
            /// Transactions that were committed with bounds no frame had been drawn for, and
            /// the longest time until the frame came, in milliseconds.
            var commitsWithoutAFrame = 0
            var longestWithoutAFrame = 0.0

            var description: String {
                func text(_ size: CGSize?) -> String { size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none" }
                return "frames=\(frames) draws=\(draws) uploads=\(uploads)"
                    + String(format: " worstCommitted=%.2f px (frame %d) worstWhenDrawn=%.2f px movedOn=%d (worst %.2f px)",
                             Double(worstCommitted), worstFrame, Double(worstWhenDrawn), movedOnFrames, Double(worstMovedOn))
                    + " captured=\(text(captured)) shownAtCapture=\(text(shownAtCapture)) psnr=\(psnr.map { String(format: "%.1f dB", $0) } ?? "none")"
                    + " finalDrawable=\(text(finalDrawable))" + String(format: " finalMismatch=%.2f px", Double(finalMismatch))
                    + String(format: " commitsWithoutAFrame=%d longest=%.1f ms", commitsWithoutAFrame, longestWithoutAFrame)
            }
        }

        /// Applies `stimulus` to the component of `bench` and judges the transition it causes.
        /// `isMidpoint` says, of what the layer says while a frame is drawn, whether the
        /// transition is half way.
        private func judge<Value>(
            _ bench: TransitionBench<Value>, isMidpoint: @escaping @MainActor (TransitionRecorder.Snapshot) -> Bool,
            stimulus: @MainActor () async throws -> Void
        ) async throws -> Verdict {
            let record = try bench.record, view = try bench.watch.view, context = try await MetalContext.shared()
            // A frame can be read back only from a drawable that allows it; the bridge's do not.
            view.framebufferOnly = false
            DrawableCapture.warmUp(context: context)
            await displayFrames(4)
            let first = record.frames.count, before = bench.watch.now, lateBefore = record.commitsWithoutAFrame
            let rest = record.snapshot(asksPresentation: false)
            let capture = Box<(taken: DrawableCapture.Taken, index: Int)?>(nil)
            record.onFrameDrawn = { view in
                // While a frame of a transition is drawn the surface has just asked the layer
                // how it is shown, at the end of the turn. The copy is only queued here: it
                // is read back when the transition is over.
                guard capture.value == nil, isMidpoint(record.snapshot()) else { return }
                if let taken = DrawableCapture.take(of: view, context: context) { capture.value = (taken, record.frames.count) }
            }
            try await stimulus()
            await bench.settle()
            record.onFrameDrawn = nil

            // The frames of the transition: from the first in which something moved to the last.
            var previous = rest
            var active: [Int] = []
            for frame in record.frames[first...] {
                let moved = frame.inTransition || frame.committed.isMoving
                    || frame.committed.model != previous.model || frame.committed.drawable != previous.drawable
                if moved { active.append(frame.index) }
                previous = frame.committed
            }
            var verdict = Verdict()
            if let start = active.first, let end = active.last {
                let frames = record.frames[start ... end]
                verdict.frames = frames.count
                if let worst = frames.filter({ !$0.layerMovedOn }).max(by: { $0.committed.mismatch < $1.committed.mismatch }) {
                    verdict.worstCommitted = worst.committed.mismatch
                    verdict.worstFrame = worst.index - start
                }
                verdict.worstWhenDrawn = frames.map(\.mismatchWhenDrawn).max() ?? 0
                verdict.movedOnFrames = frames.filter(\.layerMovedOn).count
                verdict.worstMovedOn = frames.filter(\.layerMovedOn).map(\.committed.mismatch).max() ?? 0
                let last = record.frames[end]
                verdict.draws = last.draws - before.draws
                verdict.uploads = last.uploads - before.uploads
            }
            let final = record.snapshot(asksPresentation: false)
            verdict.finalDrawable = final.drawable
            verdict.finalMismatch = final.mismatch
            verdict.commitsWithoutAFrame = record.commitsWithoutAFrame - lateBefore
            verdict.longestWithoutAFrame = record.longestWithoutAFrame * 1_000
            if let captured = capture.value, captured.index < record.frames.count, let content = bench.watch.inspector.contents.last {
                let shown = record.frames[captured.index].committed.presentationPixels
                verdict.captured = CGSize(width: captured.taken.width, height: captured.taken.height)
                verdict.shownAtCapture = shown
                let direct = try await DirectRender.image(of: content, size: shown)
                verdict.psnr = try captured.taken.frame().image().stretched(toWidth: Int(shown.width), height: Int(shown.height)).peakSignalToNoiseRatio(against: direct)
            }
            record.note("verdict \(verdict)")
            return verdict
        }

        /// Writes a verdict where the logs of the spike are, one line per run.
        private func report(_ name: String, _ verdict: Verdict) {
            print("ZTD-824 \(name): \(verdict)")
            guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = folder.appendingPathComponent("wp824-corrected-verdicts.log")
            let line = "\(name): \(verdict)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        /// The cells of the acceptance, for one transition.
        private func expectTheAcceptance(_ verdict: Verdict, of what: String) throws {
            #expect(verdict.frames >= 4, "\(what) was seen frame by frame: \(verdict)")
            #expect(verdict.worstWhenDrawn <= 1, "\(what): every frame was drawn at the size the layer was shown at, within one pixel: \(verdict)")
            #expect(verdict.worstCommitted <= 1, "\(what): at every display tick the drawable equals the presentation size within one pixel: \(verdict)")
            let psnr = try #require(verdict.psnr, "\(what): a frame was captured at the midpoint: \(verdict)")
            #expect(psnr >= 35, "\(what): the frame at the midpoint is the content rendered directly at that size: \(verdict)")
            #expect(verdict.draws >= verdict.frames - 1, "\(what): the number of draws is at least the number of ticks minus one: \(verdict)")
            #expect(verdict.uploads == 0, "\(what): nothing is uploaded")
            #expect(verdict.finalMismatch <= 1, "\(what): it ends at the exact size: \(verdict)")
        }

        // MARK: A frame that is animated

        /// A half-second animated change from 200 × 120 to 320 × 300 points.
        @Test func anAnimatedFrameChange() async throws {
            let bench = try TransitionBench<CGSize>()
            try await bench.open(Self.small, window: CGSize(width: 360, height: 420)) { size, spectrogram, probe in
                spectrogram
                    .sizeTapped(by: probe)
                    .frame(width: size.wrappedValue.width, height: size.wrappedValue.height)
            }
            let record = try bench.record
            record.note("stimulus withAnimation(linear, 0.5 s) frame -> \(TransitionRecorder.text(Self.large))")
            let verdict = try await judge(bench, isMidpoint: { $0.presentation.width >= (Self.small.width + Self.large.width) / 2 }) {
                await bench.handle.animate(to: Self.large, .linear(duration: 0.5))
            }
            bench.close(savingAs: "wp824-corrected-frame")
            report("frame", verdict)
            try expectTheAcceptance(verdict, of: "the animated frame")
            #expect(verdict.finalDrawable == LayerGeometry.pixels(Self.large, scale: record.displayScale), "it ends at the exact size: \(verdict)")
        }

        // MARK: A rotation

        /// A rotation of the interface, portrait to landscape, and back, with the component
        /// in the window all the while.
        @Test func aRotationThereAndBack() async throws {
            let bench = try TransitionBench<Int>()
            try await bench.open(0, window: nil) { _, spectrogram, probe in
                spectrogram
                    .sizeTapped(by: probe)
                    .padding(40)
            }
            let record = try bench.record, scene = try #require(bench.scene), view = try bench.watch.view
            let portrait = view.bounds.size
            let landscape = CGSize(width: portrait.height, height: portrait.width)
            // The log is written as it grows: it is there whatever a rotation does to the application.
            record.keepJournal(as: "wp824-corrected-rotation")
            record.note("stimulus requestGeometryUpdate landscapeRight")
            let there = try await judge(bench, isMidpoint: { $0.isMoving && $0.presentation.width >= (portrait.width + landscape.width) / 2 }) {
                scene.turnInterface(to: .landscapeRight) { record.note("stimulus.refused \($0)") }
                #expect(await eventually { scene.interfaceOrientation.isLandscape }, "the interface turned")
                #expect(await eventually { view.bounds.size != portrait }, "and the component with it")
                await displayFrames(20)
            }
            let turned = view.bounds.size
            report("rotation", there)
            record.note("stimulus requestGeometryUpdate portrait")
            let back = try await judge(bench, isMidpoint: { $0.isMoving && $0.presentation.width <= (portrait.width + turned.width) / 2 }) {
                scene.turnInterface(to: .portrait) { record.note("stimulus.refused \($0)") }
                #expect(await eventually { !scene.interfaceOrientation.isLandscape }, "the interface turned back")
                #expect(await eventually { view.bounds.size == portrait }, "and the component with it")
                await displayFrames(20)
            }
            let scale = record.displayScale
            bench.close(savingAs: "wp824-corrected-rotation")
            report("rotation back", back)

            #expect(turned.width > turned.height, "the component lay on its side")
            try expectTheAcceptance(there, of: "the rotation")
            #expect(there.finalDrawable == LayerGeometry.pixels(turned, scale: scale), "the drawable has the layer's size after the rotation: \(there)")
            try expectTheAcceptance(back, of: "the rotation back")
            #expect(back.finalDrawable == LayerGeometry.pixels(portrait, scale: scale), "and after the rotation back: \(back)")
        }
    }
}

extension PixelImage {
    /// The image stretched to another size, each pixel taken from between its four
    /// neighbours in the original: what the display does with a drawable that is shown at a
    /// size that is not its own.
    func stretched(toWidth newWidth: Int, height newHeight: Int) throws -> PixelImage {
        guard newWidth != width || newHeight != height else { return self }
        guard width > 0, height > 0, newWidth > 0, newHeight > 0 else { return try PixelImage(width: max(newWidth, 0), height: max(newHeight, 0), pixels: []) }
        var result = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        for y in 0 ..< newHeight {
            let sourceY = min(max((Double(y) + 0.5) * Double(height) / Double(newHeight) - 0.5, 0), Double(height - 1))
            let top = Int(sourceY), bottom = min(top + 1, height - 1), alongY = sourceY - Double(top)
            for x in 0 ..< newWidth {
                let sourceX = min(max((Double(x) + 0.5) * Double(width) / Double(newWidth) - 0.5, 0), Double(width - 1))
                let left = Int(sourceX), right = min(left + 1, width - 1), alongX = sourceX - Double(left)
                for channel in 0 ..< 4 {
                    let a = Double(pixels[(top * width + left) * 4 + channel]), b = Double(pixels[(top * width + right) * 4 + channel])
                    let c = Double(pixels[(bottom * width + left) * 4 + channel]), d = Double(pixels[(bottom * width + right) * 4 + channel])
                    let value = (a + (b - a) * alongX) * (1 - alongY) + (c + (d - c) * alongX) * alongY
                    result[(y * newWidth + x) * 4 + channel] = UInt8(min(max(value.rounded(), 0), 255))
                }
            }
        }
        return try PixelImage(width: newWidth, height: newHeight, pixels: result)
    }
}
