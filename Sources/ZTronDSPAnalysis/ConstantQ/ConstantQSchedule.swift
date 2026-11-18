import Foundation
import ZTronDSPCore
import ZTronDSPDesign

/// The low-pass every octave of a multirate constant-Q transform is halved through (WP-519,
/// §7.2 row 13): a half-band FIR, a Kaiser windowed sinc whose amplitude is one half at a
/// quarter of the sample rate.
///
/// In units of the Nyquist frequency of the rate being halved:
///
/// | Band | Edges | What the filter does |
/// |---|---|---|
/// | Pass band | 0 … 0.4 | Unity gain within 0.01 dB: this is the lower 80 % of the band of the octave below. |
/// | Transition band | 0.4 … 0.6 | Falls. What lies in 0.5 … 0.6 folds onto 0.4 … 0.5, the upper 20 % of the octave below. |
/// | Stop band | 0.6 … 1 | At least 80 dB down: everything that would fold onto the lower 80 %. |
///
/// A kernel therefore reads its octave only up to 0.8 of that octave's Nyquist frequency,
/// which is checked when a transform is made. The transition band of a half-band filter is
/// twice as wide as that of a filter that keeps the whole new band free of aliases, and its
/// length half as long: a delay that every octave below pays again.
///
/// Design maths in double precision: control context.
enum HalfBand {
    /// The upper edge of the pass band, in units of the Nyquist frequency of the rate halved.
    static let passbandEdge = 0.4
    /// The lower edge of the stop band, in the same units: `1 − passbandEdge`.
    static let stopbandEdge = 0.6
    /// The least attenuation of the stop band, in decibels (§6.8, §7.5 row 13).
    static let rejection = 80.0
    /// The share of an octave's own band, 0 Hz to its Nyquist frequency, that the decimators
    /// above it pass unchanged and keep free of aliases: `2 · passbandEdge`.
    static let cleanShare = 2 * passbandEdge

    /// The filter is the same for every transform: designed once, on first use.
    private static let design: Result<[Double], DSPError> = Result { () throws(DSPError) -> [Double] in
        try FIRDesign(
            .windowedSinc(), passband: .lowPass(cutoff: passbandEdge), stopband: .lowPass(cutoff: stopbandEdge),
            maximumLoss: .decibels(0.01), minimumAttenuation: .decibels(rejection), sampleRate: 2
        ).taps
    }

    /// The taps, lowest delay first: an odd number of them, symmetric, with unity gain at
    /// 0 Hz. Control context; the first call designs the filter.
    static func taps() throws(DSPError) -> [Double] {
        try design.get()
    }
}

/// How the octaves of a multirate constant-Q transform are laid on one another in time
/// (WP-519, WP-522b): the hop of each octave, the delay of each octave's signal, and from
/// them the delay of the whole transform.
///
/// The octave at depth `d` (0 for the highest) is read at `sampleRate / 2^d`, from the signal
/// halved `d` times. Frame `n` of the transform is centred on input sample `n · hop`, in
/// every octave, to the sample:
///
/// - The hop of depth `d` is `hop / 2^d`: whole only when `hop` is a multiple of
///   `2^(octaves − 1)`, which is the rule of O-17.
/// - A half-band filter of `K` taps delays its input by `(K − 1) / 2` samples. Halving then
///   keeps every other sample, so the signal of depth `d` lags the input by a number of input
///   samples that is in general no multiple of `2^d`: no sample of that octave would then sit
///   on `n · hop`. Feeding one zero to a decimator before its first sample moves its output
///   by one sample of its input, which is enough to make every lag whole: `primes` says for
///   which decimators that is done, and `delays` is the lag of each octave in samples of its
///   own rate.
/// - A frame of depth `d` is complete when the last sample of its longest atom has arrived.
///   The lowest octave is the last to see it; the transform's `latency` is that instant, in
///   input samples after the one the frame is centred on.
///
/// An immutable value, usable on any thread.
struct ConstantQSchedule: Hashable, Sendable {
    /// Input samples between two frames.
    let hop: Int
    /// Taps of the half-band filter between two octaves; 1 where there is one octave only.
    let filterLength: Int
    /// The longest atom of each depth, in samples of that depth's rate.
    let spans: [Int]
    /// The hop of each depth, in samples of that depth's rate.
    let hops: [Int]
    /// How far the signal of each depth lags the input, in samples of that depth's rate.
    let delays: [Int]
    /// Zeros fed to the decimator below each depth before its first sample: 0 or 1 each, one
    /// entry per decimator.
    let primes: [Int]
    /// Samples of each depth that have arrived when its frame 0 is complete.
    let firstEnds: [Int]
    /// Input samples, after the one a frame is centred on, that have arrived when the frame
    /// of each depth is complete.
    let latencies: [Int]
    /// Input samples before the one a frame is centred on that the frame still depends on:
    /// what has to pass, after a cold start, before a frame holds nothing from before it.
    let settling: Int

    /// The delay of the transform in input samples: the latest of ``latencies``.
    var latency: Int { latencies.max() ?? 0 }

    /// The octaves of the transform.
    var octaves: Int { spans.count }

    /// - Parameters:
    ///   - geometry: the bins of the transform.
    ///   - hop: input samples between two frames.
    ///   - filterLength: taps of the half-band filter, odd.
    /// - Throws: `DSPError.invalidParameter` for a hop the octaves cannot halve (O-17): the
    ///   reason names the nearest hops they can.
    init(geometry: ConstantQGeometry, hop: Int, filterLength: Int) throws(DSPError) {
        let octaves = geometry.octaves
        let step = 1 << (octaves - 1)
        guard hop >= 1, hop % step == 0 else {
            let rule = octaves == 1 ? "a hop is at least one sample" : "the hop halves from each octave to the next, so for \(octaves) octaves it is a multiple of \(step) (2^\(octaves - 1))"
            let below = hop / step * step, above = below + step
            let nearest = hop >= step && below >= step ? "the nearest are \(below) and \(above)" : "the nearest is \(step)"
            throw .invalidParameter(stage: .none, parameter: "hop", reason: "a hop of \(hop) samples cannot be used: \(rule); \(nearest)")
        }
        guard hop <= ConstantQSchedule.longestHop else {
            throw .invalidParameter(stage: .none, parameter: "hop", reason: "a hop of \(hop) samples is above the longest supported, \(ConstantQSchedule.longestHop)")
        }
        let filterDelay = (filterLength - 1) / 2
        var spans: [Int] = [], hops: [Int] = [], delays: [Int] = [0], primes: [Int] = [], firstEnds: [Int] = [], latencies: [Int] = []
        var primed = 0          // Σ primes[q] · 2^q over the decimators above the depth
        var lookBack = 0
        for depth in 0 ..< octaves {
            let span = geometry.span(atDepth: depth)
            let delay = delays[depth]
            // The frame is centred on sample `span / 2` of the span, which sits on input sample n · hop.
            let firstEnd = delay + span - span / 2
            spans.append(span)
            hops.append(hop >> depth)
            firstEnds.append(firstEnd)
            // Sample i of this depth exists once 2^depth · i − primed + 1 input samples have arrived.
            latencies.append(((firstEnd - 1) << depth) - primed + 1)
            // … and depends on input samples back to 2^depth · i − (K − 1)(2^depth − 1) − primed.
            lookBack = max(lookBack, ((span / 2 - delay) << depth) + (filterLength - 1) * ((1 << depth) - 1) + primed)
            if depth < octaves - 1 {
                let prime = (delay + filterDelay) % 2
                primes.append(prime)
                delays.append((delay + filterDelay + prime) / 2)
                primed += prime << depth
            }
        }
        self.hop = hop
        self.filterLength = filterLength
        self.spans = spans
        self.hops = hops
        self.delays = delays
        self.primes = primes
        self.firstEnds = firstEnds
        self.latencies = latencies
        self.settling = lookBack
    }

    /// The longest hop a transform takes.
    static let longestHop = 1 << 24
}
