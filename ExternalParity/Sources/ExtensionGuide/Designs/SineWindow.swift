import Foundation
import ZTronDSP

// The extension guide, row 8 of §5.11.1: a window (Docs/ExtensionGuide.md).

// snippet:begin sine-window
extension Window {
    /// The sine window, the square root of a Hann window: used for analysis and for synthesis
    /// at a hop of half a frame, the two together overlap-add to one.
    ///
    /// The closure is evaluated at t = n / N for n = 0 … N − 1, once, in double precision,
    /// when a plan is compiled (WIN-2); outside the frame the window is zero whatever the
    /// closure returns. Usable on any thread.
    public static var sine: Window {
        .custom { t in sin(.pi * t) }
    }
}
// snippet:end sine-window

// snippet:begin sine-window-use
/// An analysis and a synthesis with the sine window: what comes out is what went in, one hop
/// late. Usable on any thread.
public func sineWindowRoundTrip(frame: Int) -> Pipeline<Samples, Samples> {
    Pipeline {
        STFT(frame: frame, hop: frame / 2, window: .sine)
        InverseSTFT(window: .sine)
    }
}
// snippet:end sine-window-use
