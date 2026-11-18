import Accelerate
import ZTronDSPCore

// The analysis-thread half of the tempograms (WP-526, WP-527; §7.2 row 15): the node that
// keeps the window of the novelty curve, and the two stock transforms. Nothing here
// allocates, locks or logs after an initialiser returns; loops are `while` loops (RT-2).

/// The node of `Tempogram`: keeps the last `window` values of the novelty curve and, for
/// every new value once the window is full, hands the window to the transform with its mean
/// removed and the window function applied.
final class TempogramNode: AnalysisNode {
    private let window: Int
    /// Values the curve is led in by when the columns are centred: half a window of a linear
    /// ramp from 0 to the first value, as offline tools pad a curve.
    private let lead: Int
    /// The times of the last `latencyFrames + 1` values: a centred column keeps the time of
    /// the value it is centred on.
    private let times: AlignedBuffer<Double>
    private var slot = 0
    private let history: HistoryBuffer
    private let taper: AlignedBuffer<Float>
    private let segment: AlignedBuffer<Float>
    private let transform: any TempogramTransform
    private let rowCount: Int
    /// Values held since the last reset, the lead-in included; it stops counting at a window.
    private var held = 0

    let latencyFrames: Int
    let settlingFrames: Int

    init(window: Int, taper: [Float], alignment: FrameAlignment, transform: any TempogramTransform) throws(DSPError) {
        self.window = window
        self.transform = transform
        rowCount = transform.beatsPerMinute.count
        lead = alignment == .centered ? window / 2 : 0
        latencyFrames = Tempogram.lookAhead(window: window, alignment: alignment)
        times = try AlignedBuffer<Double>(count: latencyFrames + 1)
        // A window holds only what arrived since a reset once it is full.
        settlingFrames = window - latencyFrames
        history = try HistoryBuffer(count: window)
        self.taper = try AlignedBuffer<Float>(copying: taper)
        segment = try AlignedBuffer<Float>(count: window)
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let scalar = input.scalar, let column = output.real.baseAddress, output.real.count >= rowCount else { return }
        let value = scalar.value.isFinite ? scalar.value : 0
        if held == 0, lead > 0 {
            var index = 0
            while index < lead {
                history.append(value * Float(index) / Float(lead))
                index &+= 1
            }
            held = lead
        }
        history.append(value)
        if held < window { held &+= 1 }
        times.baseAddress[slot] = input.time
        slot &+= 1
        if slot > latencyFrames { slot = 0 }
        // Columns appear once a whole window is held (ACT-10).
        guard held >= window else { return }

        let count = vDSP_Length(window)
        let values = history.window
        // The mean out, or it swamps every tempo row; then the window function.
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, count)
        var offset = -mean
        vDSP_vsadd(values, 1, &offset, segment.baseAddress, 1, count)
        vDSP_vmul(segment.baseAddress, 1, taper.baseAddress, 1, segment.baseAddress, 1, count)
        transform.transform(UnsafePointer(segment.baseAddress), into: column)
        // The ring holds latencyFrames + 1 times: the slot that is written next is the oldest,
        // the time of the value this window is centred on (of the newest one when causal).
        output.emit(count: rowCount, time: times.baseAddress[slot])
    }

    func reset() {
        history.reset()
        held = 0
        slot = 0
    }
}

/// The rows of a tempogram inside a range of tempi, and the checks the stock transforms share.
enum TempogramRows {
    static func check(window: Int, featureRate: Double, range: ClosedRange<Double>) throws(DSPError) {
        guard window >= 2, window <= Tempogram.longestWindow else {
            throw .invalidParameter(stage: .none, parameter: "window", reason: "a tempogram window holds between 2 and \(Tempogram.longestWindow) values, not \(window)")
        }
        guard featureRate > 0, featureRate.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "featureRate", reason: "a novelty curve has a positive, finite rate, not \(featureRate)")
        }
        guard range.lowerBound > 0, range.lowerBound < range.upperBound, range.upperBound.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "range", reason: "a tempo range runs from a tempo above 0 to a higher, finite one, not from \(range.lowerBound) to \(range.upperBound)")
        }
    }
}

/// The transform of the autocorrelation tempogram: the Wiener–Khinchin relation on the
/// window, zero-padded to a fast length at or above `2·window − 1`, divided by lag 0.
final class AutocorrelationTempogramTransform: TempogramTransform {
    let beatsPerMinute: [Double]
    private let correlation: WienerKhinchin
    private let lags: AlignedBuffer<Float>
    /// The lag of each row: descending, so that the tempi ascend.
    private let rows: AlignedBuffer<Int32>
    private let rowCount: Int
    private let floor: Float

    init(window: Int, featureRate: Double, range: ClosedRange<Double>, floor: Double) throws(DSPError) {
        try TempogramRows.check(window: window, featureRate: featureRate, range: range)
        guard floor >= 0, floor.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "floor", reason: "the floor of the value at lag 0 is finite and not negative, not \(floor)")
        }
        // Lag ℓ is 60·featureRate / ℓ beats per minute: the longest lag is the slowest tempo.
        var lagsInRange: [Int] = []
        var lag = window - 1
        while lag >= 1 {
            let tempo = 60 * featureRate / Double(lag)
            if range.contains(tempo) { lagsInRange.append(lag) }
            lag -= 1
        }
        guard !lagsInRange.isEmpty else {
            throw .invalidParameter(
                stage: .none, parameter: "range",
                reason: "no lag of a window of \(window) values lies between \(range.lowerBound) and \(range.upperBound) beats per minute at \(featureRate) values per second: its lags span \(60 * featureRate / Double(window - 1)) to \(60 * featureRate) beats per minute")
        }
        beatsPerMinute = lagsInRange.map { 60 * featureRate / Double($0) }
        rowCount = lagsInRange.count
        rows = try AlignedBuffer<Int32>(copying: lagsInRange.map { Int32($0) })
        correlation = try WienerKhinchin(frame: window, lagCount: window)
        lags = try AlignedBuffer<Float>(count: window)
        self.floor = Float(floor)
    }

    func transform(_ segment: UnsafePointer<Float>, into column: UnsafeMutablePointer<Float>) {
        correlation.autocorrelate(segment, into: lags.baseAddress)
        let energy = lags.baseAddress[0]
        // 0/0 on silence, and on a curve that does not move: zeros (NUM-1).
        guard energy > floor, energy.isFinite else {
            memset(column, 0, rowCount * MemoryLayout<Float>.stride)
            return
        }
        let scale = 1 / energy
        var row = 0
        while row < rowCount {
            column[row] = lags.baseAddress[Int(rows.baseAddress[row])] * scale
            row &+= 1
        }
    }
}

/// The transform of the Fourier tempogram: the magnitudes of the bins inside the range of the
/// window's spectrum, zero-padded to a fast length at or above `resolution·window`.
final class FourierTempogramTransform: TempogramTransform {
    let beatsPerMinute: [Double]
    private let window: Int
    private let plan: any FFTPlan
    private let padded: AlignedBuffer<Float>
    private let real: AlignedBuffer<Float>
    private let imaginary: AlignedBuffer<Float>
    private let firstBin: Int
    private let rowCount: Int

    init(window: Int, featureRate: Double, range: ClosedRange<Double>, resolution: Int) throws(DSPError) {
        try TempogramRows.check(window: window, featureRate: featureRate, range: range)
        guard resolution >= 1, resolution <= 64 else {
            throw .invalidParameter(stage: .none, parameter: "resolution", reason: "a window is zero-padded to between 1 and 64 times its length, not \(resolution) times")
        }
        self.window = window
        let length = DSP.nextFastLength(resolution * window)
        // Bin k is 60·k·featureRate / length beats per minute: the bins inside the range are
        // one run, found by asking each.
        let spacing = 60 * featureRate / Double(length)
        var first = 0, last = -1
        var bin = 1
        while bin <= length / 2 {
            if range.contains(Double(bin) * spacing) {
                if last < first { first = bin }
                last = bin
            }
            bin += 1
        }
        guard last >= first else {
            throw .invalidParameter(
                stage: .none, parameter: "range",
                reason: "no bin of a transform of \(length) points lies between \(range.lowerBound) and \(range.upperBound) beats per minute at \(featureRate) values per second: its bins are \(spacing) beats per minute apart, up to \(spacing * Double(length / 2))")
        }
        firstBin = first
        rowCount = last - first + 1
        beatsPerMinute = (first ... last).map { Double($0) * spacing }
        plan = try VDSPFFTPlan(length: length)
        padded = try AlignedBuffer<Float>(count: length)
        real = try AlignedBuffer<Float>(count: length / 2 + 1)
        imaginary = try AlignedBuffer<Float>(count: length / 2 + 1)
    }

    func transform(_ segment: UnsafePointer<Float>, into column: UnsafeMutablePointer<Float>) {
        // The zeros behind the window are never written: only the window is copied.
        memcpy(padded.baseAddress, segment, window * MemoryLayout<Float>.stride)
        plan.forward(padded.baseAddress, real: real.baseAddress, imaginary: imaginary.baseAddress)
        var bins = DSPSplitComplex(realp: real.baseAddress + firstBin, imagp: imaginary.baseAddress + firstBin)
        vDSP_zvabs(&bins, 1, column, 1, vDSP_Length(rowCount))
    }
}
