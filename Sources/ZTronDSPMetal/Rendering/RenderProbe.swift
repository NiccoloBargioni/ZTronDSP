import Foundation
import ZTronDSPCore

/// Why a renderer has to draw (§8.3). The dirty set of a renderer holds exactly these causes;
/// with none of them pending nothing is drawn (V-4).
///
/// An immutable value, usable on any thread.
public struct RenderCauses: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The feed's generation moved: columns arrived, or the feed was cleared or reshaped.
    public static let newData = RenderCauses(rawValue: 1 << 0)
    /// A value that changes how the data is shown was set to something else: colour map, value
    /// range, scale, visible range. Each frame of an animation or a pinch is one such change.
    public static let appearanceChanged = RenderCauses(rawValue: 1 << 1)
    /// The drawable's size changed. Each frame of a size transition is one such change (§8.9).
    public static let drawableSizeChanged = RenderCauses(rawValue: 1 << 2)
    /// The view came on screen, or its scene became active again.
    public static let becameVisible = RenderCauses(rawValue: 1 << 3)
    /// The renderer was given a feed: at creation, and whenever it is given another one.
    public static let feedReplaced = RenderCauses(rawValue: 1 << 4)
}

/// Counts what the view layer and its renderers do, for the stability contract (§8.4): how
/// often a view was made and updated, how often a pipeline was attached, how many columns
/// were uploaded and how often a frame was drawn. A test injects one and asserts on it; a
/// view or a renderer that was given none keeps one of its own.
///
/// The renderers of this target count `uploads`, `uploadedColumns`, `draws`, `drawCalls`,
/// `allocations` and `clears`. The view layer counts the rest through the `record…` methods.
///
/// Threading: main actor, like the renderers and the views that write it.
@MainActor
public final class RenderProbe {
    /// Views made (`makeUIView`).
    public private(set) var makes = 0
    /// View updates that got past the equality check of V-3.
    public private(set) var updates = 0
    /// Pipelines a view attached to a source.
    public private(set) var attaches = 0
    /// Passes in which at least one column went to a texture.
    public private(set) var uploads = 0
    /// Columns, or envelope pairs, that went to a texture.
    public private(set) var uploadedColumns = 0
    /// Frames drawn.
    public private(set) var draws = 0
    /// Draw calls encoded, over all frames.
    public private(set) var drawCalls = 0
    /// Data textures allocated: once per renderer, and again only when the row count or the
    /// history of its feed changes (V-6).
    public private(set) var allocations = 0
    /// Times a data texture was emptied because its feed started over.
    public private(set) var clears = 0

    public init() {}

    /// A view was made.
    public func recordMake() { makes += 1 }
    /// A view update changed something.
    public func recordUpdate() { updates += 1 }
    /// A view attached a pipeline.
    public func recordAttach() { attaches += 1 }

    func recordUpload(columns: Int) {
        guard columns > 0 else { return }
        uploads += 1
        uploadedColumns += columns
    }

    func recordDraw(calls: Int) {
        draws += 1
        drawCalls += calls
    }

    func recordAllocation() { allocations += 1 }
    func recordClear() { clears += 1 }
}

/// The dirty set of a renderer and the feed generation it last drew (§8.3): what decides, on a
/// display tick, whether anything is drawn.
struct DrawLedger {
    /// Causes raised since the last draw, the arrival of data excepted: that one is read off
    /// the feed's generation.
    private(set) var raised: RenderCauses = [.feedReplaced]
    /// The feed generation the last draw showed; `nil` before the first draw of a feed.
    private(set) var shownGeneration: UInt64?

    mutating func raise(_ cause: RenderCauses) {
        raised.formUnion(cause)
    }

    /// The causes pending against the feed's present generation.
    func pending(generation: UInt64) -> RenderCauses {
        shownGeneration == generation ? raised : raised.union(.newData)
    }

    /// A frame showing the feed as of `generation` was drawn.
    mutating func settle(generation: UInt64) {
        raised = []
        shownGeneration = generation
    }

    /// Another feed: nothing of it has been shown.
    mutating func forgetFeed() {
        shownGeneration = nil
        raised.formUnion(.feedReplaced)
    }
}
