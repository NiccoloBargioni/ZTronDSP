import Foundation
import ZTronDSPCore

/// How a window of a novelty curve becomes one column of a tempogram, as a strategy (§5.3,
/// §6.9): pass `.autocorrelation` or `.fourier`, or a conformer of your own, where a
/// `Tempogram` is declared.
///
/// ```swift
/// Tempogram(.autocorrelation, window: 384)
/// Tempogram(.fourier(resolution: 8), range: 60 ... 240)
/// ```
///
/// A method is a description: an immutable value, usable on any thread, and part of the
/// description of the stage that holds it. The work is done by the transforms it makes.
public protocol TempogramMethod: Hashable, Sendable {
    /// What turns each window of `window` values of a novelty curve at `featureRate` values
    /// per second into the rows whose tempo lies inside `range`, in beats per minute.
    /// Control context: it allocates, once per plan that needs it.
    ///
    /// - Throws: `DSPError.invalidParameter` when the method's own values make no transform,
    ///   or when no row lies inside the range.
    func makeTransform(window: Int, featureRate: Double, range: ClosedRange<Double>) throws(DSPError) -> any TempogramTransform
}

/// The transform of one tempogram: a window of a novelty curve in, one column out (§6.9).
///
/// Threading: a transform is created and released on the control context. `transform`
/// allocates nothing, takes no lock and belongs to one thread at a time (the analysis thread,
/// RT-2). A transform is not `Sendable`.
public protocol TempogramTransform: AnyObject {
    /// The tempo of each row of a column, in beats per minute; at least one row. The stock
    /// methods give the rows in ascending tempo. A view labels the rows from this through the
    /// feed's axis, without knowing how they were produced.
    var beatsPerMinute: [Double] { get }

    /// One column from one window: `segment` holds the window's values with their mean
    /// removed and the window function applied; `column` takes `beatsPerMinute.count` values.
    /// The two do not overlap. No value written is NaN or infinite (NUM-1).
    func transform(_ segment: UnsafePointer<Float>, into column: UnsafeMutablePointer<Float>)
}

/// The autocorrelation tempogram (§6.9; Grosche, Müller & Kurth 2010): each window is
/// zero-padded to a fast length at or above twice its length less one, autocorrelated by FFT
/// and divided by its value at lag 0. Lag `ℓ` is the tempo `60 · featureRate / ℓ` beats per
/// minute; the rows are the lags inside the range, in ascending tempo, so they are not evenly
/// spaced. A window whose value at lag 0 does not exceed `floor` has no periodicity to speak
/// of: its column is zeros (NUM-1).
///
/// An immutable value, usable on any thread.
public struct AutocorrelationTempogram: TempogramMethod {
    /// The least value at lag 0, the energy of the windowed segment, that is divided by.
    public let floor: Double

    public init(floor: Double = 1e-10) {
        self.floor = floor
    }

    public func makeTransform(window: Int, featureRate: Double, range: ClosedRange<Double>) throws(DSPError) -> any TempogramTransform {
        try AutocorrelationTempogramTransform(window: window, featureRate: featureRate, range: range, floor: floor)
    }
}

/// The Fourier tempogram (§6.9; Grosche & Müller 2011): the magnitude spectrum of each
/// window, zero-padded to a fast length at or above `resolution` times its length. Frequency
/// `f` is the tempo `60 · f` beats per minute; the rows are the bins inside the range, evenly
/// spaced `60 · featureRate / length` beats per minute apart, in ascending tempo. Zero-padding
/// spaces the rows more finely; the window still sets what two tempi can be told apart.
///
/// An immutable value, usable on any thread.
public struct FourierTempogram: TempogramMethod {
    /// How many times its own length a window is zero-padded to: 1 to 64.
    public let resolution: Int

    public init(resolution: Int = 4) {
        self.resolution = resolution
    }

    public func makeTransform(window: Int, featureRate: Double, range: ClosedRange<Double>) throws(DSPError) -> any TempogramTransform {
        try FourierTempogramTransform(window: window, featureRate: featureRate, range: range, resolution: resolution)
    }
}

extension TempogramMethod where Self == AutocorrelationTempogram {
    /// The autocorrelation tempogram, the default.
    public static var autocorrelation: AutocorrelationTempogram { AutocorrelationTempogram() }
}

extension TempogramMethod where Self == FourierTempogram {
    /// The Fourier tempogram, zero-padded four times.
    public static var fourier: FourierTempogram { FourierTempogram() }

    /// The Fourier tempogram, zero-padded `resolution` times.
    public static func fourier(resolution: Int) -> FourierTempogram { FourierTempogram(resolution: resolution) }
}

/// A tempogram: for every value of a novelty curve, how strongly the last `window` values
/// repeat at each tempo (§6.9). One column per value, the rows being tempi.
///
/// ```swift
/// STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength()
/// Tempogram(.autocorrelation)
/// Emit(to: tempoFeed)
/// ```
///
/// - Each window has its mean removed, without which the mean would swamp the tempo rows
///   (§7.5, row 15), is multiplied by `taper`, and is transformed by the method.
/// - Only the rows inside `range`, 30 to 300 beats per minute by default, are emitted. The
///   axis downstream, and that of a feed, is `.tempo` with the tempo of each row.
/// - `alignment` is `.causal`, the default: a column describes the last `window` values, its
///   time is that of the newest one, and no latency is added. Or `.centered`: a column is
///   centred on the value its time names, as offline tools compute it, which is known
///   `window − window / 2 − 1` values later; that is the latency the step declares. The curve
///   is then led in by a linear ramp from 0 over half a window, as those tools pad it.
/// - After a start the first column appears once a whole window is held (ACT-10): `window`
///   values when causal, `window − window / 2` when centred.
/// - It follows a novelty curve (O-9), whose values arrive at the feature rate. Downstream,
///   `frameSize` is the window, `hopSize` is 1 and `featureRate` is the rate of the curve.
///
/// Switched off, it suspends the rest of its branch (ACT-3). An immutable value, usable on any
/// thread; `lower(_:)` runs on the control context.
public struct Tempogram: PipelineStage {
    public typealias Input = Novelty
    public typealias Output = TempoSpectrum

    let methodBox: AnyStrategy
    /// Values of the novelty curve per window.
    public let window: Int
    /// The window function a window of values is multiplied by.
    public let taper: Window
    /// The tempi that are emitted, in beats per minute.
    public let range: ClosedRange<Double>
    public let alignment: FrameAlignment
    public let activation: StageActivation

    public init(
        _ method: some TempogramMethod = .autocorrelation, window: Int = 384, taper: Window = .hann, range: ClosedRange<Double> = 30 ... 300,
        alignment: FrameAlignment = .causal, isActive: some ActivationSource = .active
    ) {
        self.methodBox = AnyStrategy(method)
        self.window = window
        self.taper = taper
        self.range = range
        self.alignment = alignment
        self.activation = isActive.stageActivation
    }

    /// The method the step was declared with.
    public var method: any TempogramMethod { methodBox.value(as: (any TempogramMethod).self) ?? AutocorrelationTempogram() }

    /// The longest window the step keeps.
    static let longestWindow = 1 << 16

    /// Values a centred column waits for after the one its time names.
    static func lookAhead(window: Int, alignment: FrameAlignment) -> Int {
        alignment == .centered ? window - window / 2 - 1 : 0
    }

    /// Everything that determines the node, and nothing else (F5, SWAP-1).
    struct Key: Hashable, Sendable {
        let method: AnyStrategy
        let window: Int
        let taper: [Float]
        let range: ClosedRange<Double>
        let alignment: FrameAlignment
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let rate = context.environment.sampleRate
        guard rate > 0, rate.isFinite else { throw context.invalid("sampleRate", "a tempogram needs the rate of the novelty curve, and there is none here") }
        let window = try StageValidation.value(window, named: "window", in: 2 ... Tempogram.longestWindow, context: context)
        guard range.lowerBound > 0, range.lowerBound < range.upperBound, range.upperBound.isFinite else {
            throw context.invalid("range", "a tempo range runs from a tempo above 0 to a higher, finite one, in beats per minute, not from \(range.lowerBound) to \(range.upperBound)")
        }
        let samples = try SampledWindow(taper, frame: window).single
        let method = method
        // Made once here for its rows, which the axis and the size of a column are read from.
        let rows = try method.makeTransform(window: window, featureRate: rate, range: range).beatsPerMinute
        guard !rows.isEmpty, rows.allSatisfy(\.isFinite) else {
            throw context.invalid("range", "\(type(of: method)) gives no row between \(range.lowerBound) and \(range.upperBound) beats per minute")
        }
        let alignment = alignment, range = range
        let ahead = Tempogram.lookAhead(window: window, alignment: alignment)
        context.emit(.analysis(AnalysisStep(
            name: "Tempogram", key: Key(method: methodBox, window: window, taper: samples, range: range, alignment: alignment),
            output: .real(count: rows.count), scope: .spectral(frameSize: window, hopSize: 1, axis: .tempo(beatsPerMinute: rows)),
            latency: Double(ahead) / rate
        ) { () throws(DSPError) -> any AnalysisNode in
            try TempogramNode(
                window: window, taper: samples, alignment: alignment,
                transform: method.makeTransform(window: window, featureRate: rate, range: range))
        }))
    }
}

extension Pipeline where Output == Novelty {
    /// The tempogram of the novelty curve: see ``Tempogram``.
    public func tempogram(
        _ method: some TempogramMethod = .autocorrelation, window: Int = 384, taper: Window = .hann, range: ClosedRange<Double> = 30 ... 300,
        alignment: FrameAlignment = .causal, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, TempoSpectrum> {
        appending(Tempogram(method, window: window, taper: taper, range: range, alignment: alignment, isActive: isActive))
    }
}
