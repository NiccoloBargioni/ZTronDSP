import Foundation
import ZTronDSP

// The extension guide, row 7 of §5.11.1: a design or a strategy (Docs/ExtensionGuide.md).

// snippet:begin damped-family
/// A filter family with all its poles on one real point: critically damped. Its step response
/// never overshoots, at the price of a soft knee. The cutoff is the −3 dB point.
///
/// A family supplies one thing, its analog low-pass prototype; the frequency transformation,
/// the bilinear transform and the section pairing are the package's, the same as for a stock
/// family. An immutable value, usable on any thread; designing allocates and belongs on a
/// control or background context.
public struct CriticallyDampedFamily: FilterFamily {
    public init() {}

    /// `order` poles at −p, with p chosen so that the gain at 1 rad/s is 1/√2.
    public func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
        guard order >= 1, order <= 64 else {
            throw .invalidParameter(stage: .none, parameter: "order", reason: "a critically damped filter has between 1 and 64 poles, not \(order)")
        }
        let pole = 1 / (pow(2, 1 / Double(order)) - 1).squareRoot()
        return ZeroPoleGain(zeros: [], poles: [Complex](repeating: Complex(-pole), count: order), gain: pow(pole, Double(order)), domain: .analog)
    }
}

extension FilterFamily where Self == CriticallyDampedFamily {
    /// No overshoot: every pole on one real point. Usable on any thread.
    public static var criticallyDamped: CriticallyDampedFamily { CriticallyDampedFamily() }
}
// snippet:end damped-family
