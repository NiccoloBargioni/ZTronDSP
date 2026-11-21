import Foundation
import ZTronDSPCore

extension WindowAnalysis: MATLABExportable {
    /// The analysis as a MATLAB script (§6.14): the window, and its spectrum with markers for
    /// the main lobe and the highest side lobe. Core MATLAB only, so it also runs in GNU
    /// Octave; equal analyses give equal text (MAT-2, MAT-4).
    ///
    /// The call may be made from any context; the work runs on the background executor (BG-1,
    /// MAT-6) and can be cancelled. It allocates, in the background.
    public func matlabScript() async throws(DSPError) -> String {
        let analysis = self
        return try await BackgroundWork.run { checkpoint throws(DSPError) in
            try checkpoint.check()
            return try analysis.script().text
        }
    }

    /// The script, built where it is called.
    func script() throws(DSPError) -> MATLABScript {
        let floor = -160.0
        return try MATLABScript()
            .comment("Window analysis: \(window), \(frame) samples" + (hop.map { ", hop \($0)" } ?? ""))
            .scalar("frame", Double(frame))
            .vector("samples", samples)
            .scalar("bin_step", spectrumBinStep)
            .vector("spectrum_db", spectrum.map { Swift.max($0, floor) })
            .scalar("peak", peak)
            .scalar("coherent_gain", coherentGain)
            .scalar("noise_gain", noiseGain)
            .scalar("equivalent_noise_bandwidth", equivalentNoiseBandwidth ?? .nan)
            .scalar("main_lobe_half_power", mainLobeWidthAtHalfPower)
            .scalar("main_lobe_null_to_null", mainLobeWidthNullToNull ?? .nan)
            .scalar("peak_side_lobe", peakSideLobe ?? .nan)
            .scalar("side_lobe_fall_off", sideLobeFallOff ?? .nan)
            .scalar("scalloping_loss", scallopingLoss)
            .scalar("smoothness", Double(smoothness))
            .subplot(2, 1, 1)
            .plot("0:frame-1", "samples")
            .xlabel("sample")
            .ylabel("amplitude")
            .title("Window: \(window)")
            .grid()
            .subplot(2, 1, 2)
            .plot("(0:numel(spectrum_db)-1) * bin_step", "spectrum_db")
            .hold()
            .plot("[main_lobe_half_power main_lobe_half_power] / 2", "[\(MATLABScript.format(floor)) 0]", style: "r--")
            .plot("[main_lobe_null_to_null main_lobe_null_to_null] / 2", "[\(MATLABScript.format(floor)) 0]", style: "m--")
            .plot("[0 frame/2]", "[peak_side_lobe peak_side_lobe]", style: "g--")
            .hold(false)
            .axis(x: 0 ... Double(frame) / 2, y: floor ... 5)
            .xlabel("frequency (bins)")
            .ylabel("level (dB)")
            .title("Spectrum: main lobe at -3 dB (red), first null (magenta), highest side lobe (green)")
            .grid()
    }
}
