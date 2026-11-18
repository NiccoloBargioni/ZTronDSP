import Foundation
import ZTronDSPCore

// MATLAB export of frames (§6.14, WP-540): the snapshot of a heat-map or waveform feed, a
// track of scalar frames, an inversion report. Every script defines its data as variables and
// then plots them, with core MATLAB only, so it also runs in GNU Octave (MAT-2); equal input
// gives equal text (MAT-4); the work runs in the background (MAT-6).

extension FeedSnapshot: MATLABExportable {
    /// The snapshot as a MATLAB script: a heat map as an image with its row axis and its
    /// frame times, a waveform as its minimum and maximum over time.
    ///
    /// Rows that are evenly spaced (linear frequency, quefrency, lags, positions) are drawn
    /// against their values. Rows that are not (mel bands, constant-Q bins, tempi) are drawn
    /// against their index, because an image has evenly spaced rows; their values are in the
    /// script as `row_values`.
    ///
    /// - Throws: `DSPError.exportTooLarge` for more than four million values (MAT-4);
    ///   `DSPError.cancelled`.
    public func matlabScript() async throws(DSPError) -> String {
        let snapshot = self
        return try await BackgroundWork.run { checkpoint throws(DSPError) in
            try checkpoint.check()
            return try snapshot.script().text
        }
    }

    func script() throws(DSPError) -> MATLABScript {
        switch content {
        case .waveform:
            var script = try MATLABScript()
                .comment("Waveform envelope: \(columnCount) pairs")
                .vector("times", times)
                .vector("minima", minima)
                .vector("maxima", maxima)
            guard columnCount > 0 else { return script }
            script = script
                .plot("times", "maxima")
                .hold()
                .plot("times", "minima")
                .hold(false)
                .xlabel("time (s)")
                .ylabel("amplitude")
                .title("Waveform envelope")
                .grid()
            return script
        case .heatmap:
            let rows = rowCount, columns = columnCount
            // The snapshot holds column after column; a MATLAB matrix is written row after row.
            var matrix = [Float](repeating: 0, count: rows * columns)
            for column in 0 ..< columns {
                for row in 0 ..< rows { matrix[row * columns + column] = values[column * rows + row] }
            }
            let rowValues = (0 ..< rows).map { axis?.value(ofRow: $0) ?? Double($0) }
            let (label, isEven) = FeedSnapshot.rowLabel(of: axis)
            var script = try MATLABScript()
                .comment("Heat map: \(rows) rows, \(columns) columns")
                .vector("times", times)
                .vector("row_values", rowValues)
                .matrix("values", values: matrix, rows: rows, columns: columns)
            guard rows > 0, columns > 0 else { return script }
            script = script
                .imagesc("times", isEven ? "row_values" : "1:numel(row_values)", "values")
                .colorbar()
                .xlabel("time (s)")
                .ylabel(isEven ? label : "row (\(label) in row_values)")
                .title("Heat map")
            return script
        }
    }

    /// What the rows are called, and whether they are evenly spaced.
    static func rowLabel(of axis: FeedAxis?) -> (label: String, isEvenlySpaced: Bool) {
        switch axis {
        case .linearFrequency?: ("frequency (Hz)", true)
        case .mel?: ("mel band centre (Hz)", false)
        case .constantQ?: ("constant-Q bin frequency (Hz)", false)
        case .pitchClasses?: ("pitch class", true)
        case .lags?: ("lag (s)", true)
        case .quefrency?: ("quefrency (s)", true)
        case .tempo?: ("tempo (beats per minute)", false)
        case .indices?, nil: ("index", true)
        }
    }
}

/// A track of scalar frames with the time of each: what a step that reduces the signal to one
/// value produces over time, kept for an export (§6.14).
///
/// ```swift
/// let pitch: [ScalarFrame] = try pipeline.process(samples, format: format)
/// let script = try await ScalarTrack(pitch, rate: 93.75).matlabScript()
/// ```
///
/// An immutable value, usable on any thread.
public struct ScalarTrack: Hashable, Sendable, MATLABExportable {
    public let frames: [ScalarFrame]
    /// The time of each frame, in seconds.
    public let times: [Double]

    /// A track from frames and the time of each. The longer array is cut to the shorter.
    public init(_ frames: [ScalarFrame], times: [Double]) {
        let count = Swift.min(frames.count, times.count)
        self.frames = Array(frames.prefix(count))
        self.times = Array(times.prefix(count))
    }

    /// A track from frames that follow one another at `rate` values per second, the first at
    /// `start` seconds.
    public init(_ frames: [ScalarFrame], rate: Double, start: Double = 0) {
        self.frames = frames
        self.times = frames.indices.map { rate > 0 ? start + Double($0) / rate : start }
    }

    /// The track as a MATLAB script: value and confidence over time.
    ///
    /// - Throws: `DSPError.exportTooLarge` for more than four million frames (MAT-4);
    ///   `DSPError.cancelled`.
    public func matlabScript() async throws(DSPError) -> String {
        let track = self
        return try await BackgroundWork.run { checkpoint throws(DSPError) in
            try checkpoint.check()
            return try track.script().text
        }
    }

    func script() throws(DSPError) -> MATLABScript {
        let script = try MATLABScript()
            .comment("Scalar track: \(frames.count) frames")
            .vector("times", times)
            .vector("values", frames.map { $0.value })
            .vector("confidence", frames.map { $0.confidence })
        guard !frames.isEmpty else { return script }
        return script
            .subplot(2, 1, 1)
            .plot("times", "values")
            .xlabel("time (s)")
            .ylabel("value")
            .title("Scalar track")
            .grid()
            .subplot(2, 1, 2)
            .plot("times", "confidence")
            .xlabel("time (s)")
            .ylabel("confidence")
            .grid()
    }
}

extension InversionReport: MATLABExportable {
    /// The report as a MATLAB script: the original, the reconstruction and their difference,
    /// and the spectrum of the difference (INV-4). Without a measured round trip the script
    /// holds the figures of the report and plots nothing.
    ///
    /// - Throws: `DSPError.exportTooLarge` for more than four million values (MAT-4);
    ///   `DSPError.cancelled`.
    public func matlabScript() async throws(DSPError) -> String {
        let report = self
        return try await BackgroundWork.run { checkpoint throws(DSPError) in
            try checkpoint.check()
            return try report.script().text
        }
    }

    func script() throws(DSPError) -> MATLABScript {
        var script = try MATLABScript()
            .comment("Inversion report: \(stage) and back through \(inverse)")
            .comment(isExactlyInvertible ? "Every necessary condition holds." : "A necessary condition fails.")
            .scalar("predicted_error", predictedError)
        for condition in conditions {
            script = script.comment("\(condition.name): \(condition.holds ? "holds" : "fails"), margin \(MATLABScript.format(condition.margin))")
        }
        guard let roundTrip, let measuredError, !roundTrip.original.isEmpty else { return script }
        let isFrames = roundTrip.frameLength > 1
        script = try script
            .scalar("sample_rate", sampleRate)
            .scalar("measured_snr", measuredError.signalToNoiseRatio)
            .scalar("largest_error", measuredError.largestError)
            .vector("original", roundTrip.original)
            .vector("reconstruction", roundTrip.reconstruction)
        let position = isFrames ? "0:numel(original)-1" : "(0:numel(original)-1) / sample_rate"
        let frequency = isFrames ? "(0:numel(original)-1) / numel(original)" : "(0:numel(original)-1) * sample_rate / numel(original)"
        return script
            .subplot(3, 1, 1)
            .plot(position, "original")
            .hold()
            .plot(position, "reconstruction", style: "r--")
            .hold(false)
            .xlabel(isFrames ? "value" : "time (s)")
            .ylabel("amplitude")
            .title("Original and reconstruction (dashed)")
            .grid()
            .subplot(3, 1, 2)
            .plot(position, "original - reconstruction")
            .xlabel(isFrames ? "value" : "time (s)")
            .ylabel("error")
            .title("Error")
            .grid()
            .subplot(3, 1, 3)
            .plot(frequency, "20 * log10(abs(fft(original - reconstruction)) + 1e-300)")
            .xlabel(isFrames ? "cycles per value" : "frequency (Hz)")
            .ylabel("level (dB)")
            .title("Spectrum of the error")
            .grid()
    }
}
