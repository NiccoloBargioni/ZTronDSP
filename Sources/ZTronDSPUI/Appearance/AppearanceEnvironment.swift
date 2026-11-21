import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// What an appearance modifier was given: a value, or a binding to one (VC-4).
///
/// A component reads the value of either. A pinch writes a binding, and keeps the scaled
/// value itself for a constant (PINCH-5).
///
/// A binding is read and written on the main actor only.
enum AppearanceSetting<Value: Equatable & Sendable>: Sendable {
    case constant(Value)
    case bound(Binding<Value>)

    /// The value now.
    @MainActor var value: Value {
        switch self {
        case .constant(let value): value
        case .bound(let binding): binding.wrappedValue
        }
    }

    /// The value, when it was given as a constant.
    var constant: Value? {
        if case .constant(let value) = self { return value }
        return nil
    }

}

/// SwiftUI asks this to decide whether an environment value changed, and so whether the views
/// that read it are evaluated again. Two constants are equal when their values are. A binding
/// offers no identity, so a setting that holds one never counts as unchanged: a component is
/// then evaluated again, reads the binding, and compares what it reads with what it shows
/// (V-3). Without this conformance SwiftUI would compare the stored bytes, of which a
/// constant uses only a part.
extension AppearanceSetting: Equatable {
    static func == (lhs: AppearanceSetting, rhs: AppearanceSetting) -> Bool {
        if case .constant(let left) = lhs, case .constant(let right) = rhs { return left == right }
        return false
    }
}

/// Which axes a component shows beside its picture (VC-2): what `.axis(_:)` names.
///
/// `frequency`, `pitchClass` and `tempo` all name the vertical axis, the one that says what
/// the rows are. The labels come from the feed's `FeedAxis` (VC-5), so a component shows the
/// same axis for each of the three; the three names exist so that code reads as what it
/// shows. `time` names the horizontal axis.
///
/// An immutable value, usable on any thread; it does not allocate.
public enum DSPAxis: Hashable, Sendable {
    /// The vertical axis of a spectrogram: frequencies, on the scale the view uses.
    case frequency
    /// The horizontal axis: seconds before now.
    case time
    /// The vertical axis of a chromagram: the twelve pitch classes.
    case pitchClass
    /// The vertical axis of a tempogram: beats per minute.
    case tempo

    /// True for the three names of the vertical axis.
    var isVertical: Bool { self != .time }
}

// MARK: Keys

// Every appearance modifier sets one value in the SwiftUI environment (VC-4). The keys are
// internal: the modifiers are the API. `nil` means that no modifier said anything, and the
// component uses its own default.
//
// Each default is one stored value, not a value made anew for every reader. SwiftUI decides
// whether a view that reads the environment is evaluated again by comparing what it read
// with what it read before, as stored, and an optional that holds nothing has storage that
// nobody ever wrote: two that are made separately need not compare equal.

/// The axes a component shows: what the `.axis(_:)` modifiers add up to. A plain set of
/// flags, so that the same axes are the same bits.
struct ShownAxes: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    /// The vertical axis: what the rows are.
    static let rows = ShownAxes(rawValue: 1)
    /// The horizontal axis: time.
    static let time = ShownAxes(rawValue: 2)

    /// The flag for one of the public names.
    static func axis(_ axis: DSPAxis) -> ShownAxes {
        axis.isVertical ? .rows : .time
    }
}

private struct ColorMapKey: EnvironmentKey {
    static let defaultValue: AnyColorMap? = nil
}

private struct ValueRangeKey: EnvironmentKey {
    static let defaultValue: AppearanceSetting<ClosedRange<Float>>? = nil
}

private struct FrequencyScaleKey: EnvironmentKey {
    static let defaultValue: AnyFrequencyScale? = nil
}

private struct FrequencyRangeKey: EnvironmentKey {
    static let defaultValue: AppearanceSetting<ClosedRange<Double>>? = nil
}

private struct TimeSpanKey: EnvironmentKey {
    static let defaultValue: AppearanceSetting<Double>? = nil
}

private struct AmplitudeRangeKey: EnvironmentKey {
    static let defaultValue: AppearanceSetting<ClosedRange<Float>>? = nil
}

private struct MaximumFrameRateKey: EnvironmentKey {
    static let defaultValue = 60
}

private struct PinchAxesKey: EnvironmentKey {
    static let defaultValue: Axis.Set = []
}

private struct ShownAxesKey: EnvironmentKey {
    static let defaultValue: ShownAxes = []
}

private struct RenderProbeKey: EnvironmentKey {
    static let defaultValue: RenderProbe? = nil
}

private struct ClockSourceKey: EnvironmentKey {
    static let defaultValue: ClockSource? = nil
}

private struct SurfaceInspectorKey: EnvironmentKey {
    static let defaultValue: SurfaceInspector? = nil
}

private struct PinchScriptKey: EnvironmentKey {
    static let defaultValue: PinchScript? = nil
}

private struct PinchPathKey: EnvironmentKey {
    static let defaultValue: PinchPath? = nil
}

/// Where the views of a hierarchy get their display clocks from: the seam through which a
/// hosted test hands them clocks it fires itself. Without one, every view makes a
/// `DisplayLinkClock`.
///
/// Threading: main actor.
@MainActor
final class ClockSource {
    private let make: @MainActor () -> any FrameClock

    init(_ make: @escaping @MainActor () -> any FrameClock) {
        self.make = make
    }

    func makeClock() -> any FrameClock {
        make()
    }
}

extension EnvironmentValues {
    var dspColorMap: AnyColorMap? {
        get { self[ColorMapKey.self] }
        set { self[ColorMapKey.self] = newValue }
    }

    var dspValueRange: AppearanceSetting<ClosedRange<Float>>? {
        get { self[ValueRangeKey.self] }
        set { self[ValueRangeKey.self] = newValue }
    }

    var dspFrequencyScale: AnyFrequencyScale? {
        get { self[FrequencyScaleKey.self] }
        set { self[FrequencyScaleKey.self] = newValue }
    }

    var dspFrequencyRange: AppearanceSetting<ClosedRange<Double>>? {
        get { self[FrequencyRangeKey.self] }
        set { self[FrequencyRangeKey.self] = newValue }
    }

    var dspTimeSpan: AppearanceSetting<Double>? {
        get { self[TimeSpanKey.self] }
        set { self[TimeSpanKey.self] = newValue }
    }

    var dspAmplitudeRange: AppearanceSetting<ClosedRange<Float>>? {
        get { self[AmplitudeRangeKey.self] }
        set { self[AmplitudeRangeKey.self] = newValue }
    }

    var dspMaximumFrameRate: Int {
        get { self[MaximumFrameRateKey.self] }
        set { self[MaximumFrameRateKey.self] = newValue }
    }

    var dspPinchAxes: Axis.Set {
        get { self[PinchAxesKey.self] }
        set { self[PinchAxesKey.self] = newValue }
    }

    var dspShownAxes: ShownAxes {
        get { self[ShownAxesKey.self] }
        set { self[ShownAxesKey.self] = newValue }
    }

    /// The probe the surfaces and pipeline hosts of a hierarchy count into: how the hosted
    /// stability tests inject one (§8.4). `nil` lets every surface keep one of its own.
    var dspRenderProbe: RenderProbe? {
        get { self[RenderProbeKey.self] }
        set { self[RenderProbeKey.self] = newValue }
    }

    /// The display clocks of the hierarchy, when a test supplies them.
    var dspClockSource: ClockSource? {
        get { self[ClockSourceKey.self] }
        set { self[ClockSourceKey.self] = newValue }
    }

    /// Sees what the surfaces of the hierarchy show, when a test wants to.
    var dspSurfaceInspector: SurfaceInspector? {
        get { self[SurfaceInspectorKey.self] }
        set { self[SurfaceInspectorKey.self] = newValue }
    }

    /// The gesture path the surfaces of the hierarchy install, when a test names one; `nil`
    /// is the path of the OS.
    var dspPinchPath: PinchPath? {
        get { self[PinchPathKey.self] }
        set { self[PinchPathKey.self] = newValue }
    }

    /// Plays pinches into the surfaces of the hierarchy, when a test supplies one.
    var dspPinchScript: PinchScript? {
        get { self[PinchScriptKey.self] }
        set { self[PinchScriptKey.self] = newValue }
    }
}
