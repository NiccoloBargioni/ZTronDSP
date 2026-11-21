import CoreGraphics
import Foundation
import MetalKit
import QuartzCore
import SwiftUI
import Testing
import UIKit
import ZTronDSP
import ZTronDSPMetal
@testable import ZTronDSPUI

/// A spectrogram of a still picture in a window of the application, with a recorder on its
/// Metal view and a size probe behind it: what the spike and the acceptance both look at.
@MainActor
final class TransitionBench<Value> {
    let watch = Watch()
    let handle = StateHandle<Value>()
    let feed: HeatmapFeed
    private let probe = Box<TransitionRecorder?>(nil)
    private var recorder: TransitionRecorder?
    private var closeWindow: (() -> Void)?
    private(set) var window: UIWindow?
    private(set) var scene: UIWindowScene?

    init() throws {
        // A still picture with something to see at every size: a stretched or shifted copy
        // differs from a true one.
        feed = HeatmapFeed(history: 96)
        try FeedWriter.append(FeedWriter.pattern(columns: 96, rows: 48), rows: 48, to: feed)
    }

    var record: TransitionRecorder {
        get throws { try #require(recorder, "the bench is open") }
    }

    /// Hosts what `content` makes of the spectrogram over a piece of state, and starts
    /// recording. `window` is the size of the window; `nil` fills the application's scene,
    /// as a window that turns with the interface does.
    func open<Content: View>(
        _ initial: Value, window size: CGSize?,
        @ViewBuilder content: @escaping (Binding<Value>, SpectrogramView, Box<TransitionRecorder?>) -> Content
    ) async throws {
        let scene = try await AppScene.active()
        self.scene = scene
        let feed = feed, probe = probe
        let hosted = try await hostWatched(initial, handle, watch: watch, size: size ?? scene.coordinateSpace.bounds.size) { binding in
            content(binding, SpectrogramView(feed: feed), probe)
        }
        if size == nil { hosted.window.frame = scene.coordinateSpace.bounds }
        window = hosted.window
        closeWindow = { hosted.close() }
        await displayFrames(6)
        let record = try TransitionRecorder(watch)
        recorder = record
        probe.value = record
        await displayFrames(2)
    }

    /// True when nothing moves any more: the layer carries no animation and the coordinator
    /// is in no transition. The layer is not asked how it is shown (see `TransitionRecorder`).
    var isAtRest: Bool {
        guard let recorder, let coordinator = try? watch.coordinator else { return true }
        return !recorder.isAnimated && !coordinator.isInSizeTransition
    }

    /// Waits until the transition is over and a few frames of the display more.
    func settle() async {
        #expect(await eventually { self.isAtRest }, "the transition ends")
        await displayFrames(8)
        #expect(await eventually { self.isAtRest })
    }

    /// Stops recording, writes the log when a name is given, and closes the window.
    func close(savingAs name: String? = nil) {
        if let name { recorder?.save(as: name) }
        recorder?.stop()
        probe.value = nil
        closeWindow?()
        closeWindow = nil
    }
}
