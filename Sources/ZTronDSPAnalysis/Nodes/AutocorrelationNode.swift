import Accelerate
import ZTronDSPCore

/// The node of `Autocorrelation` (WP-515): frames a sampled sequence with its own window and
/// hop and turns each frame into its lags by the Wiener–Khinchin relation.
///
/// The sequence arrives as blocks of samples, or as one value per frame after a novelty curve
/// or a scalar track; either way the values go through one framer.
///
/// Analysis thread: nothing here allocates, locks or logs after the initialiser returns.
final class AutocorrelationNode: AnalysisNode {
    private let window: Int
    private let lagCount: Int
    private let normalization: CorrelationNormalization
    private let floor: Float
    private let sampleRate: Double
    private let framer: Framer
    private let mixer: ChannelMixer
    private let transform: WienerKhinchin
    /// `1 / (window − ℓ)` for every lag that has a product, 0 for the others: the weights of
    /// the unbiased normalisation.
    private let weights: AlignedBuffer<Float>
    /// Samples taken since the last reset: the position of the next one.
    private var position = 0

    var latencyFrames: Int { 0 }
    let settlingFrames: Int

    init(
        window: Int, hop: Int, lagCount: Int, normalization: CorrelationNormalization, floor: Float, transform: WienerKhinchin,
        mixer: ChannelMixer, sampleRate: Double
    ) throws(DSPError) {
        self.window = window
        self.lagCount = lagCount
        self.normalization = normalization
        self.floor = floor
        self.transform = transform
        self.mixer = mixer
        self.sampleRate = sampleRate
        framer = try Framer(frameSize: window, hopSize: hop, alignment: .causal)
        weights = try AlignedBuffer<Float>(count: lagCount)
        var lag = 0
        while lag < lagCount, lag < window {
            weights.baseAddress[lag] = 1 / Float(window - lag)
            lag &+= 1
        }
        // A frame holds only what arrived since a reset once a whole window has arrived.
        settlingFrames = window
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let lags = output.real.baseAddress, output.real.count >= lagCount else { return }
        if let block = input.samples {
            let total = block.frameCount
            let origin = position
            var done = 0
            while done < total {
                let count = min(total - done, mixer.chunk)
                let samples = mixer.sequence(of: block, from: done, count: count)
                var offset = 0
                while offset < count {
                    offset += framer.append(samples + offset, count: count - offset)
                    while let view = framer.frame {
                        correlate(view, into: lags)
                        // A frame describes the window that ends at its newest sample.
                        output.emit(count: lagCount, time: input.time + Double(framer.framePosition - origin) / sampleRate)
                        framer.advance()
                    }
                }
                done += count
            }
            position &+= total
        } else if let scalar = input.scalar {
            // One value of a feature-rate sequence: the frame it completes carries its time.
            var value = scalar.value
            var taken = 0
            while taken < 1 {
                taken += framer.append(&value, count: 1)
                while let view = framer.frame {
                    correlate(view, into: lags)
                    output.emit(count: lagCount, time: input.time)
                    framer.advance()
                }
            }
            position &+= 1
        }
    }

    /// The lags of one frame, normalised.
    private func correlate(_ frame: UnsafePointer<Float>, into lags: UnsafeMutablePointer<Float>) {
        transform.autocorrelate(frame, into: lags)
        let count = vDSP_Length(lagCount)
        switch normalization {
        case .none:
            break
        case .biased:
            var scale = 1 / Float(window)
            vDSP_vsmul(lags, 1, &scale, lags, 1, count)
        case .unbiased:
            vDSP_vmul(lags, 1, weights.baseAddress, 1, lags, 1, count)
        case .coefficient:
            let energy = lags[0]
            // A frame without energy has no coefficient: zeros, and nothing is divided by a
            // value at lag 0 that is zero, below the floor, or not a number (NUM-1).
            if energy > floor, energy.isFinite {
                var scale = 1 / energy
                vDSP_vsmul(lags, 1, &scale, lags, 1, count)
                // The value at lag 0 over itself: exactly 1, not the round-off of a reciprocal.
                lags[0] = 1
            } else {
                memset(lags, 0, lagCount * MemoryLayout<Float>.stride)
            }
        }
    }

    func reset() {
        framer.reset()
        position = 0
    }
}
