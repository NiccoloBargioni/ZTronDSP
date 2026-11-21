import Foundation
import os
import ZTronDSPCore

/// The window diagnostics of an attachment (WIN-5): for a window written `.logged()` the
/// analysis is run once when its framing step is made, on the control context, and written to
/// `os.Logger`, category `window`, one line per property. Otherwise nothing is logged.
enum WindowDiagnostics {
    private static let logger = Logger(subsystem: "com.zombietron.ztrondsp", category: "window")

    /// Where a test hears what is logged on its task. `nil` outside a test.
    @TaskLocal static var recorder: (@Sendable ([String]) -> Void)?

    /// Analyses `window` on the frame and hop of the step that holds it and logs the report.
    /// Control context: it allocates, and it is never called from the analysis thread.
    static func logAttachment(of window: Window, frame: Int, hop: Int) {
        // The window was sampled when its step was lowered, so the analysis exists; a window
        // that cannot be analysed has nothing to log.
        guard let analysis = try? WindowAnalysis(window, frame: frame, hop: hop, tail: nil, checkpoint: nil) else { return }
        let lines = analysis.lines
        for line in lines { logger.info("\(line, privacy: .public)") }
        recorder?(lines)
    }
}

extension WindowAnalysis: CustomStringConvertible {
    /// The report, one line per property: what a logged window writes (WIN-5). Usable on any
    /// thread; it allocates the lines.
    public var lines: [String] {
        func number(_ value: Double?) -> String { value.map { String(format: "%.6g", $0) } ?? "not defined" }
        func answer(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "not examined" }
        let tail: String
        switch tailLimit {
        case .zero?: tail = "0"
        case .value(let value)?: tail = "\(String(format: "%.6g", value)) (a truncated function, not a window)"
        case .unbounded?: tail = "unbounded (a truncated function, not a window)"
        case .undefined?: tail = "no limit (a truncated function, not a window)"
        case nil: tail = "not examined (the function of a custom window is not known outside the frame)"
        }
        let jumps = discontinuities.isEmpty
            ? "none" : discontinuities.map { "\(String(format: "%.6g", $0.size)) at \(String(format: "%.6g", $0.position))" }.joined(separator: ", ")
        var result = [
            "window \(window): \(frame) samples" + (hop.map { ", hop \($0)" } ?? ""),
            "symmetric: \(answer(isSymmetric)); non-negative: \(answer(isNonNegative)); finite: \(answer(isFinite))",
            "peak: \(number(peak))",
            "coherent gain: \(number(coherentGain))",
            "noise gain: \(number(noiseGain))",
            "equivalent noise bandwidth: \(number(equivalentNoiseBandwidth)) bins",
            "amplitude normalisation factor: \(number(amplitudeNormalization)); power normalisation factor: \(number(powerNormalization))",
            "limit far outside the frame: \(tail)",
            "edge values: \(number(leadingEdgeValue)) and \(number(trailingEdgeValue))",
            "discontinuities: \(jumps)",
            "smoothness: \(smoothness) (side lobes predicted to fall by \(number(-predictedSideLobeFallOff)) dB per octave)",
            "absolutely integrable: on the frame \(answer(isAbsolutelyIntegrableOnFrame)), on the line \(answer(isAbsolutelyIntegrableOnLine))",
            "square integrable: on the frame \(answer(isSquareIntegrableOnFrame)), on the line \(answer(isSquareIntegrableOnLine))",
            "main lobe: \(number(mainLobeWidthAtHalfPower)) bins at -3 dB, \(number(mainLobeWidthNullToNull)) bins null to null",
            "peak side lobe: \(number(peakSideLobe)) dB",
            "side-lobe fall-off: \(number(sideLobeFallOff)) dB per octave",
            "scalloping loss: \(number(scallopingLoss)) dB",
        ]
        if hop != nil {
            result.append("non-zero overlap-add: \(answer(isNonZeroOverlapAdd)); constant overlap-add: \(answer(isConstantOverlapAdd)); "
                + "ripple: \(number(overlapRipple)); frame-bound ratio: \(number(frameBoundRatio))")
        }
        return result
    }

    /// The report as text: ``lines``, one per line. Usable on any thread; it allocates the text.
    public var description: String { lines.joined(separator: "\n") }
}
