import Accelerate
import ZTronDSPCore

// The two implementations of the mel projection (WP-535, §7.4): banded dot products, and one
// dense product. Which one a plan holds is decided when it is compiled (SEL-3).
//
// Analysis thread: nothing here allocates, locks or logs after an initialiser returns.

/// Each bin belongs to at most two bands, so a band is a short run of weights: one dot
/// product per band. The bands are sorted, when the node is made, by the implementation the
/// length of their run is bound to, so the loops below hold no test of a size.
final class BandedMelNode: AnalysisNode {
    private let binCount: Int
    private let bandCount: Int
    private let weights: AlignedBuffer<Float>
    private let offsets: AlignedBuffer<Int32>
    private let firstBins: AlignedBuffer<Int32>
    private let counts: AlignedBuffer<Int32>
    /// The bands in the order they are computed: a scalar loop, the 8-lane loop, vDSP.
    private let order: AlignedBuffer<Int32>
    private let scalarEnd: Int
    private let laneEnd: Int

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(_ bank: MelFilterBank, crossovers: CrossoverTable, requested: Implementation) throws(DSPError) {
        binCount = bank.binCount
        bandCount = bank.bandCount
        var total = 0
        var band = 0
        while band < bank.bandCount {
            total += bank.bands[band].weights.count
            band += 1
        }
        weights = try AlignedBuffer<Float>(count: total)
        offsets = try AlignedBuffer<Int32>(count: bank.bandCount)
        firstBins = try AlignedBuffer<Int32>(count: bank.bandCount)
        counts = try AlignedBuffer<Int32>(count: bank.bandCount)
        order = try AlignedBuffer<Int32>(count: bank.bandCount)

        var offset = 0
        band = 0
        while band < bank.bandCount {
            let run = bank.bands[band]
            offsets.baseAddress[band] = Int32(offset)
            firstBins.baseAddress[band] = Int32(run.firstBin)
            counts.baseAddress[band] = Int32(run.weights.count)
            var index = 0
            while index < run.weights.count {
                weights.baseAddress[offset + index] = run.weights[index]
                index += 1
            }
            offset += run.weights.count
            band += 1
        }

        // 0: the scalar loop; 1: the 8-lane loop; 2: vDSP.
        var placed = 0
        var kind = 0
        var ends = (0, 0)
        while kind < 3 {
            band = 0
            while band < bank.bandCount {
                let length = bank.bands[band].weights.count
                let implementation = crossovers.implementation(for: .reduction, size: length, requested: requested)
                let own = implementation == .accelerate ? 2 : (crossovers.reductionUsesSIMD(count: length) ? 1 : 0)
                if own == kind {
                    order.baseAddress[placed] = Int32(band)
                    placed += 1
                }
                band += 1
            }
            if kind == 0 { ends.0 = placed }
            if kind == 1 { ends.1 = placed }
            kind += 1
        }
        scalarEnd = ends.0
        laneEnd = ends.1
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= binCount, let spectrum = frame.values.baseAddress,
              let result = output.real.baseAddress
        else { return }
        let table = UnsafePointer(weights.baseAddress)
        var position = 0
        while position < scalarEnd {
            let band = Int(order.baseAddress[position])
            result[band] = Vector.Native.dot(table + Int(offsets.baseAddress[band]), spectrum + Int(firstBins.baseAddress[band]), count: Int(counts.baseAddress[band]))
            position &+= 1
        }
        while position < laneEnd {
            let band = Int(order.baseAddress[position])
            result[band] = Vector.Native.dotSIMD(table + Int(offsets.baseAddress[band]), spectrum + Int(firstBins.baseAddress[band]), count: Int(counts.baseAddress[band]))
            position &+= 1
        }
        while position < bandCount {
            let band = Int(order.baseAddress[position])
            result[band] = Vector.Accelerated.dot(table + Int(offsets.baseAddress[band]), spectrum + Int(firstBins.baseAddress[band]), count: Int(counts.baseAddress[band]))
            position &+= 1
        }
        output.emit(count: bandCount)
    }

    func reset() {}
}

/// The whole bank as one matrix and one `cblas_sgemv`: what pays when bands × bins is large.
final class DenseMelNode: AnalysisNode {
    private let binCount: Int
    private let bandCount: Int
    private let matrix: AlignedBuffer<Float>

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(_ bank: MelFilterBank) throws(DSPError) {
        binCount = bank.binCount
        bandCount = bank.bandCount
        matrix = try AlignedBuffer<Float>(copying: bank.denseWeights())
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= binCount, let spectrum = frame.values.baseAddress,
              let result = output.real.baseAddress
        else { return }
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(bandCount), Int32(binCount), 1, matrix.baseAddress, Int32(binCount), spectrum, 1, 0, result, 1)
        output.emit(count: bandCount)
    }

    func reset() {}
}
