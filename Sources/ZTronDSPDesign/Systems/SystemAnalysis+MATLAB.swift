import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

// The MATLAB export of a system analysis (§6.14, WP-440).

extension SystemAnalysis: MATLABExportable {
    /// The number of frequencies the exported responses are sampled at. Usable on any thread.
    public static let exportedFrequencyCount = 512
    /// The number of samples of the exported impulse and step responses. Usable on any thread.
    public static let exportedSampleCount = 256

    /// The analysis as a MATLAB script (§6.14): its data as variables, then the plots.
    ///
    /// | Variable | Holds |
    /// |---|---|
    /// | `sample_rate` | the sample rate, in hertz |
    /// | `z`, `p`, `k` | zeros, poles and gain |
    /// | `f` | 512 frequencies in hertz, evenly spaced in pitch |
    /// | `magnitude_db`, `phase_rad`, `group_delay` | the responses at `f`: decibels no lower than the floor of −160 dB (NUM-1), the unwrapped phase in radians, the delay in samples (seconds for an analog system); a group delay that is undefined is `NaN` |
    /// | `n`, `impulse`, `step` | 256 samples of the impulse and of the step response, for a stable digital system |
    ///
    /// The plots are the pole–zero map (with the unit circle for a digital system; its axes in
    /// radians per second for an analog one), the magnitude, the unwrapped phase, the group
    /// delay and, for a stable digital system, the impulse and step responses. The script uses
    /// core MATLAB only, so it also runs in GNU Octave (MAT-2); numbers are written so that they
    /// read back exactly (MAT-3); it carries no date and no machine name, so equal analyses give
    /// equal text (MAT-4). The package writes no file: what comes back is text (MAT-5).
    ///
    /// The call may be made from any context; the work runs on `BackgroundWork` (BG-1, MAT-6) and
    /// can be cancelled (BG-3). It allocates, in the background.
    ///
    /// - Throws: `DSPError.cancelled`; `DSPError.exportTooLarge` cannot occur for the sizes
    ///   above.
    public func matlabScript() async throws(DSPError) -> String {
        try await BackgroundWork.run { (checkpoint: BackgroundWork.Checkpoint) throws(DSPError) -> String in
            try self.script(checkpoint: checkpoint).text
        }
    }

    /// The frequencies the export samples the responses at, in hertz: for a digital system
    /// from a 4 096th of the sample rate to the Nyquist frequency; for an analog one from a
    /// hundredth of its slowest root to a hundred times its fastest.
    func exportedFrequencies() -> [Double] {
        let count = Self.exportedFrequencyCount
        let lowest: Double
        let highest: Double
        switch domain {
        case .digital:
            lowest = sampleRate / 4_096
            highest = sampleRate / 2
        case .analog:
            let rates = (zeros + poles).map(\.magnitude).filter { $0 > 0 && $0.isFinite }
            lowest = (rates.min() ?? 2 * Double.pi) / (2 * Double.pi) / 100
            highest = (rates.max() ?? 2 * Double.pi * 1_000) / (2 * Double.pi) * 100
        }
        let ratio = highest / lowest
        return (0 ..< count).map { lowest * pow(ratio, Double($0) / Double(count - 1)) }
    }

    /// The script, built step by step.
    func script(checkpoint: BackgroundWork.Checkpoint? = nil) throws(DSPError) -> MATLABScript {
        let isDigital = domain == .digital
        let hertz = exportedFrequencies()
        let angular = hertz.map { isDigital ? 2 * Double.pi * $0 / sampleRate : 2 * Double.pi * $0 }
        let magnitude = try magnitudeResponse(at: angular, in: .decibels)
        let phase = try phaseResponse(at: angular, unwrapped: true)
        let delay = try groupDelay(at: angular)
        try checkpoint?.check()

        // The time responses exist for what a kernel runs: a stable digital system.
        var impulse: [Float]?
        var step: [Float]?
        if isDigital, isStable, realization != nil {
            impulse = try impulseResponse(count: Self.exportedSampleCount)
            try checkpoint?.check()
            step = try stepResponse(count: Self.exportedSampleCount)
        }
        try checkpoint?.check()

        var script = MATLABScript()
            .comment("ZTronDSP system analysis: \(isDigital ? "a digital" : "an analog") system of order \(order), \(kind == .finiteImpulseResponse ? "finite" : "infinite") impulse response, \(isStable ? "stable" : "not stable").")
        script = try script.scalar("sample_rate", sampleRate)
        script = try script.vector("z", real: zeros.map(\.real), imaginary: zeros.map(\.imaginary))
        script = try script.vector("p", real: poles.map(\.real), imaginary: poles.map(\.imaginary))
        script = try script.scalar("k", gain)
        script = try script.vector("f", hertz)
        script = try script.vector("magnitude_db", magnitude)
        script = try script.vector("phase_rad", phase)
        script = try script.vector("group_delay", optional: delay)
        if let impulse, let step {
            script = try script.vector("n", (0 ..< impulse.count).map { Double($0) })
            script = try script.vector("impulse", impulse)
            script = try script.vector("step", step)
        }

        let rows = impulse == nil ? 2 : 3
        script = script.subplot(rows, 2, 1)
            .plot("real(z)", "imag(z)", style: "o")
            .hold(true)
            .plot("real(p)", "imag(p)", style: "x")
        if isDigital {
            script = script.plot("cos(linspace(0, 2 * pi, 361))", "sin(linspace(0, 2 * pi, 361))", style: "k:")
        }
        // The z-plane has no unit; the s-plane is in radians per second (MAT-2: labels and units).
        script = script.hold(false).axis("equal").grid()
            .xlabel(isDigital ? "Real part" : "Real part (rad/s)").ylabel(isDigital ? "Imaginary part" : "Imaginary part (rad/s)")
            .title(isDigital ? "Poles (x) and zeros (o), with the unit circle" : "Poles (x) and zeros (o)")
        script = script.subplot(rows, 2, 2).semilogx("f", "magnitude_db").grid()
            .xlabel("Frequency (Hz)").ylabel("Magnitude (dB)").title("Magnitude response")
        script = script.subplot(rows, 2, 3).semilogx("f", "phase_rad").grid()
            .xlabel("Frequency (Hz)").ylabel("Phase (rad)").title("Phase response, unwrapped")
        script = script.subplot(rows, 2, 4).semilogx("f", "group_delay").grid()
            .xlabel("Frequency (Hz)").ylabel(isDigital ? "Group delay (samples)" : "Group delay (s)").title("Group delay")
        if impulse != nil {
            script = script.subplot(rows, 2, 5).stem("n", "impulse").grid()
                .xlabel("Sample").ylabel("Amplitude").title("Impulse response")
            script = script.subplot(rows, 2, 6).stem("n", "step").grid()
                .xlabel("Sample").ylabel("Amplitude").title("Step response")
        }
        return script
    }
}
