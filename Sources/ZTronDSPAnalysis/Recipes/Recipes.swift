import Foundation
import ZTronDSPCore

// The recipes of the spectral front-end (§5.2): stages defined entirely by what they expand
// to. A pipeline that holds one equals a pipeline that holds its expansion, description for
// description, and both compile to the same plan: equal framing in several recipes is
// computed once (F5).

/// A spectrogram into a feed: `Tap { STFT; Power; Decibels; Emit(to: feed) }`.
///
/// ```swift
/// let feed = HeatmapFeed(history: 940)
/// Pipeline { Spectrogram(frame: 2_048, hop: 512, to: feed) }
/// ```
///
/// The samples pass on unchanged: the analysis is a side branch. With the default
/// normalisation, `.amplitude`, a full-scale sine reads 0 dB whatever the frame and the
/// window, so one value range suits every setting; `.none` gives the plain transform.
/// Switched off, the branch is suspended and the feed is no longer live (ACT-3, ACT-11). An
/// immutable value, usable on any thread; creating one allocates its expansion.
public struct Spectrogram: Recipe {
    /// Audio samples.
    public typealias Input = Samples
    /// The same samples: the analysis is a side branch.
    public typealias Output = Samples

    /// What the recipe stands for: the tap of the transform, the powers, the decibels and the
    /// sink.
    public let expansion: Pipeline<Samples, Samples>
    /// The recipe's switch: off, the branch is suspended and the feed is no longer live (ACT-3,
    /// ACT-11).
    public let activation: StageActivation

    /// A spectrogram of frames of `frame` samples every `hop` samples under `window`, scaled by
    /// `normalization`, into `feed`. The values are checked when the pipeline is compiled.
    public init(
        frame: Int = 2_048, hop: Int = 512, window: Window = .hann, normalization: WindowNormalization = .amplitude,
        to feed: HeatmapFeed, isActive: some ActivationSource = .active
    ) {
        activation = isActive.stageActivation
        expansion = Pipeline {
            Tap(isActive: isActive) {
                STFT(frame: frame, hop: hop, window: window, normalization: normalization)
                Power()
                Decibels()
                Emit(to: feed)
            }
        }
    }
}

/// A mel spectrogram into a feed: `Tap { STFT; Power; MelScale; Decibels; Emit(to: feed) }`
/// (§6.11).
///
/// The samples pass on unchanged. The transform is not normalised, as the offline tools that
/// compute mel spectrograms leave it; the feed's axis gives the centre of each band in hertz.
/// Switched off, the branch is suspended (ACT-3). An immutable value, usable on any thread;
/// creating one allocates its expansion.
public struct MelSpectrogram: Recipe {
    /// Audio samples.
    public typealias Input = Samples
    /// The same samples: the analysis is a side branch.
    public typealias Output = Samples

    /// What the recipe stands for: the tap of the transform, the powers, the mel bands, the
    /// decibels and the sink.
    public let expansion: Pipeline<Samples, Samples>
    /// The recipe's switch: off, the branch is suspended (ACT-3).
    public let activation: StageActivation

    /// A mel spectrogram of `bands` bands across `range`, from frames of `frame` samples every
    /// `hop` samples under `window`, into `feed`. The values are checked when the pipeline is
    /// compiled (O-18).
    public init(
        frame: Int = 2_048, hop: Int = 512, bands: Int = 128, window: Window = .hann, range: FrequencyRange? = nil,
        to feed: HeatmapFeed, isActive: some ActivationSource = .active
    ) {
        activation = isActive.stageActivation
        expansion = Pipeline {
            Tap(isActive: isActive) {
                STFT(frame: frame, hop: hop, window: window)
                Power()
                MelScale(bands: bands, range: range)
                Decibels()
                Emit(to: feed)
            }
        }
    }
}

/// Mel-frequency cepstral coefficients into a feed or a binding:
/// `Tap { STFT; Power; MelScale; Decibels; CepstralCoefficients; Emit }` (§6.6).
///
/// The samples pass on unchanged. A `Binding<[Float]>` receives a new array per delivery, at
/// the result rate (OUT-5); a `HeatmapFeed` receives every frame. Switched off, the branch is
/// suspended (ACT-3). An immutable value, usable on any thread; creating one allocates its
/// expansion.
public struct MFCC: Recipe {
    /// Audio samples.
    public typealias Input = Samples
    /// The same samples: the analysis is a side branch.
    public typealias Output = Samples

    /// What the recipe stands for: the tap of the transform, the powers, the mel bands, the
    /// decibels, the coefficients and the sink.
    public let expansion: Pipeline<Samples, Samples>
    /// The recipe's switch: off, the branch is suspended (ACT-3).
    public let activation: StageActivation

    /// `count` coefficients from `melBands` mel bands of frames of `frame` samples every `hop`
    /// samples under `window`, into `feed`, which receives every frame.
    public init(
        frame: Int = 2_048, hop: Int = 512, count: Int = 13, melBands: Int = 40, window: Window = .hann,
        to feed: HeatmapFeed, isActive: some ActivationSource = .active
    ) {
        activation = isActive.stageActivation
        expansion = Pipeline {
            Tap(isActive: isActive) {
                STFT(frame: frame, hop: hop, window: window)
                Power()
                MelScale(bands: melBands)
                Decibels()
                CepstralCoefficients(count: count)
                Emit(to: feed)
            }
        }
    }

    /// The same coefficients into `binding`, a `Binding<[Float]>`, which receives a new array per
    /// delivery, on the main thread and at the result rate (OUT-5).
    public init(
        frame: Int = 2_048, hop: Int = 512, count: Int = 13, melBands: Int = 40, window: Window = .hann,
        to binding: some VectorResultTarget, isActive: some ActivationSource = .active
    ) {
        activation = isActive.stageActivation
        expansion = Pipeline {
            Tap(isActive: isActive) {
                STFT(frame: frame, hop: hop, window: window)
                Power()
                MelScale(bands: melBands)
                Decibels()
                CepstralCoefficients(count: count)
                Emit(to: binding)
            }
        }
    }
}

extension Pipeline where Output == Samples {
    /// A spectrogram of the signal into a feed; the samples pass on: see ``Spectrogram``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func spectrogram(
        frame: Int = 2_048, hop: Int = 512, window: Window = .hann, normalization: WindowNormalization = .amplitude,
        to feed: HeatmapFeed, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Samples> {
        appending(Spectrogram(frame: frame, hop: hop, window: window, normalization: normalization, to: feed, isActive: isActive))
    }

    /// A mel spectrogram of the signal into a feed; the samples pass on: see ``MelSpectrogram``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func melSpectrogram(
        frame: Int = 2_048, hop: Int = 512, bands: Int = 128, window: Window = .hann, range: FrequencyRange? = nil,
        to feed: HeatmapFeed, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Samples> {
        appending(MelSpectrogram(frame: frame, hop: hop, bands: bands, window: window, range: range, to: feed, isActive: isActive))
    }

    /// Cepstral coefficients of the signal into a feed; the samples pass on: see ``MFCC``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func mfcc(
        frame: Int = 2_048, hop: Int = 512, count: Int = 13, melBands: Int = 40, window: Window = .hann,
        to feed: HeatmapFeed, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Samples> {
        appending(MFCC(frame: frame, hop: hop, count: count, melBands: melBands, window: window, to: feed, isActive: isActive))
    }

    /// Cepstral coefficients of the signal into a binding; the samples pass on: see ``MFCC``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func mfcc(
        frame: Int = 2_048, hop: Int = 512, count: Int = 13, melBands: Int = 40, window: Window = .hann,
        to binding: some VectorResultTarget, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Samples> {
        appending(MFCC(frame: frame, hop: hop, count: count, melBands: melBands, window: window, to: binding, isActive: isActive))
    }
}
