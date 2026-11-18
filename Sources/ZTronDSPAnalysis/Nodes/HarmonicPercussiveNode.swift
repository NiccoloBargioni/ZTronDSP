import Accelerate
import ZTronDSPCore

/// The masks of a harmonic–percussive separation for one frame (WP-530): from the median
/// along time and the median along frequency to the share of each bin that the chosen
/// component gets. It is what the streaming node and the offline separation share.
///
/// Created on the control context or in background work. `mask` allocates nothing, takes no
/// lock and belongs to one thread at a time (RT-2).
final class SeparationMasks {
    private let binCount: Int
    private let strategy: any MaskStrategy
    private let harmonicMargin: Float
    private let percussiveMargin: Float
    private let floor: Float
    /// A median times the margin of the other side: the competitor a mask is taken against.
    private let scaled: AlignedBuffer<Float>
    private let other: AlignedBuffer<Float>

    init(binCount: Int, strategy: any MaskStrategy, harmonicMargin: Float, percussiveMargin: Float, floor: Float) throws(DSPError) {
        self.binCount = binCount
        self.strategy = strategy
        self.harmonicMargin = harmonicMargin
        self.percussiveMargin = percussiveMargin
        self.floor = floor
        scaled = try AlignedBuffer<Float>(count: binCount)
        other = try AlignedBuffer<Float>(count: binCount)
    }

    /// The harmonic mask: the time median against the frequency median times its margin.
    func harmonic(_ timeMedian: UnsafePointer<Float>, _ frequencyMedian: UnsafePointer<Float>, into mask: UnsafeMutablePointer<Float>) {
        var margin = harmonicMargin
        vDSP_vsmul(frequencyMedian, 1, &margin, scaled.baseAddress, 1, vDSP_Length(binCount))
        strategy.mask(timeMedian, against: UnsafePointer(scaled.baseAddress), floor: floor, into: mask, count: binCount)
    }

    /// The percussive mask: the frequency median against the time median times its margin.
    func percussive(_ timeMedian: UnsafePointer<Float>, _ frequencyMedian: UnsafePointer<Float>, into mask: UnsafeMutablePointer<Float>) {
        var margin = percussiveMargin
        vDSP_vsmul(timeMedian, 1, &margin, scaled.baseAddress, 1, vDSP_Length(binCount))
        strategy.mask(frequencyMedian, against: UnsafePointer(scaled.baseAddress), floor: floor, into: mask, count: binCount)
    }

    /// The mask of `component`. The residual is what the two masks leave, and never negative.
    func mask(
        _ component: HarmonicPercussiveComponent, timeMedian: UnsafePointer<Float>, frequencyMedian: UnsafePointer<Float>,
        into mask: UnsafeMutablePointer<Float>
    ) {
        switch component {
        case .harmonic:
            harmonic(timeMedian, frequencyMedian, into: mask)
        case .percussive:
            percussive(timeMedian, frequencyMedian, into: mask)
        case .residual:
            let count = vDSP_Length(binCount)
            harmonic(timeMedian, frequencyMedian, into: mask)
            percussive(timeMedian, frequencyMedian, into: other.baseAddress)
            // 1 − M_H − M_P, held at 0 where round-off would take it below.
            vDSP_vadd(mask, 1, other.baseAddress, 1, mask, 1, count)
            var minusOne: Float = -1, one: Float = 1
            vDSP_vsmsa(mask, 1, &minusOne, &one, mask, 1, count)
            var zero: Float = 0
            vDSP_vthr(mask, 1, &zero, mask, 1, count)
        }
    }
}

/// The node of `HarmonicPercussive` (WP-531a, WP-531b): the medians of the magnitudes along
/// time and along frequency, the mask of the chosen component, and the frame under that mask.
///
/// The filter along time gives, for every frame that arrives, the median of the last
/// `timeKernel` frames. Causal, that is the median of the frame that arrived. Centred, it is
/// the median of the frame `lookAhead` frames back, which the node has kept: magnitudes, and
/// for a complex spectrum the bins themselves, since the mask is applied to them.
///
/// On a complex spectrum a centred node is a delay line of `lookAhead` frames, and begins as
/// one: while its first frame waits for its look-ahead it writes frames of silence, so that
/// a frame leaves for every frame that arrives and a resynthesis keeps its place in the
/// stream. On magnitudes, which have no way back to samples, it writes nothing until then.
///
/// Analysis thread: nothing here allocates, locks or logs after the initialiser returns.
final class HarmonicPercussiveNode: AnalysisNode {
    private let component: HarmonicPercussiveComponent
    private let binCount: Int
    private let isComplex: Bool
    private let lookAhead: Int
    /// Seconds a frame of the lead-in lies before the frame that arrives with it.
    private let leadIn: Double
    private let timeMedian: any MedianFilter
    private let frequencyMedian: any MedianFilter
    private let masks: SeparationMasks
    /// The frames of the last `lookAhead + 1` arrivals, as a ring: magnitudes, and the real
    /// and imaginary parts of a complex spectrum.
    private let magnitudes: AlignedBuffer<Float>
    private let reals: AlignedBuffer<Float>
    private let imaginaries: AlignedBuffer<Float>
    /// The times of the frames in the ring: a frame that is written late keeps its own.
    private let times: AlignedBuffer<Double>
    private let harmonic: AlignedBuffer<Float>
    private let percussive: AlignedBuffer<Float>
    private let mask: AlignedBuffer<Float>
    /// Frames since the last reset.
    private var seen = 0
    /// The slot of the ring the next frame goes to.
    private var slot = 0

    let latencyFrames: Int
    let settlingFrames: Int

    init(
        component: HarmonicPercussiveComponent, binCount: Int, isComplex: Bool, lookAhead: Int, settling: Int, timeMedian: any MedianFilter,
        frequencyMedian: any MedianFilter, mask: any MaskStrategy, harmonicMargin: Float, percussiveMargin: Float, floor: Float, featureRate: Double
    ) throws(DSPError) {
        self.component = component
        self.binCount = binCount
        self.isComplex = isComplex
        self.lookAhead = lookAhead
        leadIn = Double(lookAhead) / featureRate
        self.timeMedian = timeMedian
        self.frequencyMedian = frequencyMedian
        masks = try SeparationMasks(binCount: binCount, strategy: mask, harmonicMargin: harmonicMargin, percussiveMargin: percussiveMargin, floor: floor)
        let ring = (lookAhead + 1) * binCount
        magnitudes = try AlignedBuffer<Float>(count: ring)
        reals = try AlignedBuffer<Float>(count: isComplex ? ring : 0)
        imaginaries = try AlignedBuffer<Float>(count: isComplex ? ring : 0)
        times = try AlignedBuffer<Double>(count: lookAhead + 1)
        harmonic = try AlignedBuffer<Float>(count: binCount)
        percussive = try AlignedBuffer<Float>(count: binCount)
        self.mask = try AlignedBuffer<Float>(count: binCount)
        latencyFrames = lookAhead
        // A frame rests on frames that all arrived since a reset once the time kernel is full.
        settlingFrames = max(settling, 0)
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        let count = vDSP_Length(binCount)
        let bytes = binCount * MemoryLayout<Float>.stride
        let arrived = magnitudes.baseAddress + slot &* binCount
        if isComplex {
            guard let spectrum = input.complex, spectrum.count >= binCount, let real = spectrum.real.baseAddress,
                  let imaginary = spectrum.imaginary.baseAddress, output.real.count >= binCount, output.imaginary.count >= binCount
            else { return }
            var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: real), imagp: UnsafeMutablePointer(mutating: imaginary))
            vDSP_zvabs(&split, 1, arrived, 1, count)
            memcpy(reals.baseAddress + slot &* binCount, real, bytes)
            memcpy(imaginaries.baseAddress + slot &* binCount, imaginary, bytes)
        } else {
            guard let frame = input.real, frame.count >= binCount, let values = frame.values.baseAddress, output.real.count >= binCount else { return }
            memcpy(arrived, values, bytes)
        }
        times.baseAddress[slot] = input.time
        // The median of the last `timeKernel` frames: of this frame when causal, of the frame
        // `lookAhead` back when centred.
        timeMedian.process(UnsafePointer(arrived), into: harmonic.baseAddress)
        slot &+= 1
        if slot > lookAhead { slot = 0 }
        seen &+= 1
        // Centred, the first frame is known once its look-ahead has arrived. Until then a
        // complex stream is led in by silence, each frame stamped with the time of the frame
        // whose place it takes.
        guard seen > lookAhead else {
            if isComplex, let target = output.real.baseAddress, let quadrature = output.imaginary.baseAddress {
                memset(target, 0, bytes)
                memset(quadrature, 0, bytes)
                output.emit(count: binCount, time: input.time - leadIn)
            }
            return
        }

        // The ring holds lookAhead + 1 frames: the slot that is written next is the oldest.
        let centre = slot
        let centreMagnitudes = UnsafePointer(magnitudes.baseAddress + centre &* binCount)
        frequencyMedian.process(centreMagnitudes, into: percussive.baseAddress)
        masks.mask(component, timeMedian: UnsafePointer(harmonic.baseAddress), frequencyMedian: UnsafePointer(percussive.baseAddress), into: mask.baseAddress)

        guard let target = output.real.baseAddress else { return }
        if isComplex, let quadrature = output.imaginary.baseAddress {
            // The mask is real: the phase of every bin is kept.
            vDSP_vmul(reals.baseAddress + centre &* binCount, 1, mask.baseAddress, 1, target, 1, count)
            vDSP_vmul(imaginaries.baseAddress + centre &* binCount, 1, mask.baseAddress, 1, quadrature, 1, count)
        } else {
            vDSP_vmul(centreMagnitudes, 1, mask.baseAddress, 1, target, 1, count)
        }
        // The frame keeps the time of the spectrum it describes.
        output.emit(count: binCount, time: times.baseAddress[centre])
    }

    func reset() {
        timeMedian.reset()
        frequencyMedian.reset()
        seen = 0
        slot = 0
    }
}
