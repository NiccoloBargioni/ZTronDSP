import Foundation
import ZTronDSP

// The extension guide, row 10 of §5.11.1: an export (Docs/ExtensionGuide.md).

// snippet:begin novelty-export
/// A novelty curve as an app keeps it: the values a pipeline delivered and how many of them
/// make a second. It exports as a MATLAB script.
///
/// An immutable value, usable on any thread.
public struct NoveltyCurve: MATLABExportable, Hashable {
    public let values: [Float]
    /// Values per second: the feature rate of the pipeline that delivered them.
    public let rate: Double

    public init(_ frames: [ScalarFrame], rate: Double) {
        values = frames.map(\.value)
        self.rate = rate
    }

    /// The script: the curve as variables, then one plot with its axes labelled. Core MATLAB
    /// only, so it also runs in GNU Octave (MAT-2); no date and no machine name, so equal
    /// curves give equal text (MAT-4). The package writes no file: the text is the app's.
    ///
    /// May be called from any context, the main actor included: the work runs on the
    /// package's background executor (BG-1) and can be cancelled (BG-3).
    public func matlabScript() async throws(DSPError) -> String {
        let values = values, rate = rate
        return try await BackgroundWork.run { checkpoint throws(DSPError) -> String in
            guard rate > 0, rate.isFinite else {
                throw .invalidParameter(stage: .none, parameter: "rate", reason: "a curve has a positive number of values per second, not \(rate)")
            }
            let times = (0 ..< values.count).map { Double($0) / rate }
            try checkpoint.check()
            return try MATLABScript()
                .comment("Novelty curve: \(values.count) values at \(MATLABScript.format(rate)) per second")
                .vector("t", times)
                .vector("novelty", values)
                .plot("t", "novelty")
                .xlabel("Time (s)")
                .ylabel("Novelty")
                .title("Novelty curve")
                .grid()
                .text
        }
    }
}
// snippet:end novelty-export
