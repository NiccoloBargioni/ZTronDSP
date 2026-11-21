import Foundation

/// What the rows of a feed are (VC-5). A feed carries its axis, and the environment carries
/// it inside a spectral scope, so a view labels rows without knowing how they were produced.
///
/// An immutable value, usable on any thread; reading it does not allocate.
public enum FeedAxis: Hashable, Sendable {
    /// Bins evenly spaced in hertz: row `k` is `k · nyquist / (binCount − 1)`.
    case linearFrequency(binCount: Int, nyquist: Double)
    /// Mel bands, by the centre of each band in hertz.
    case mel(centers: [Double])
    /// Constant-Q bins: row `k` is `minimumFrequency · 2^(k / binsPerOctave)`.
    case constantQ(minimumFrequency: Double, binsPerOctave: Int, binCount: Int)
    /// The twelve pitch classes, C first.
    case pitchClasses
    /// Autocorrelation lags: row `k` is `k / sampleRate` seconds.
    case lags(count: Int, sampleRate: Double)
    /// Quefrencies: row `k` is `k / sampleRate` seconds.
    case quefrency(count: Int, sampleRate: Double)
    /// Tempi, by the tempo of each row in beats per minute.
    case tempo(beatsPerMinute: [Double])
    /// Rows that are plain positions: cepstral coefficients, or the frames of a domain defined
    /// outside the package.
    case indices(count: Int)

    /// The unit of ``value(ofRow:)``.
    ///
    /// A value, usable on any thread; it does not allocate.
    public enum Unit: Hashable, Sendable {
        /// Hertz: the frequency axes.
        case hertz
        /// Seconds: lags and quefrencies.
        case seconds
        /// Beats per minute: tempi.
        case beatsPerMinute
        /// Pitch classes, 0 for C up to 11 for B.
        case pitchClass
        /// Plain positions, from 0.
        case index
    }

    /// The unit the rows are measured in.
    public var unit: Unit {
        switch self {
        case .linearFrequency, .mel, .constantQ: .hertz
        case .lags, .quefrency: .seconds
        case .tempo: .beatsPerMinute
        case .pitchClasses: .pitchClass
        case .indices: .index
        }
    }

    /// The number of rows.
    public var rowCount: Int {
        switch self {
        case .linearFrequency(let count, _): count
        case .mel(let centers): centers.count
        case .constantQ(_, _, let count): count
        case .pitchClasses: 12
        case .lags(let count, _), .quefrency(let count, _), .indices(let count): count
        case .tempo(let values): values.count
        }
    }

    /// What row `row` stands for, in ``unit``. A row outside `0 ..< rowCount` is clamped to
    /// the nearest row; an axis without rows gives 0.
    public func value(ofRow row: Int) -> Double {
        let count = rowCount
        guard count > 0 else { return 0 }
        let index = min(max(row, 0), count - 1)
        switch self {
        case .linearFrequency(_, let nyquist):
            return count > 1 ? Double(index) * nyquist / Double(count - 1) : 0
        case .mel(let centers):
            return centers[index]
        case .constantQ(let minimum, let binsPerOctave, _):
            return minimum * pow(2, Double(index) / Double(max(binsPerOctave, 1)))
        case .pitchClasses, .indices:
            return Double(index)
        case .lags(_, let rate), .quefrency(_, let rate):
            return rate > 0 ? Double(index) / rate : 0
        case .tempo(let values):
            return values[index]
        }
    }

    /// The names of the twelve pitch classes, in row order.
    public static let pitchClassNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// True when the rows are frequencies evenly spaced in hertz, which is what a view's
    /// `.frequencyScale` may warp for display (VC-5).
    public var isLinearFrequency: Bool {
        if case .linearFrequency = self { return true }
        return false
    }
}
