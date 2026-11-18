// expect: initializer is inaccessible due to 'internal' protection level
//
// FINDING. An AnalysisNode writes through a FrameWriter, and a FrameWriter cannot be made outside ZTronDSPCore: its initialiser is internal (@usableFromInline). The author of a node cannot call process(_:_:) in a test of his own, and cannot hold it inside expectNoAllocations: a node runs only inside a plan. This fixture fails the day the initialiser, or a harness in ZTronDSPTesting, is public.
import ExternalStages
import SwiftUI
import ZTronDSP

var counter = 0
var storage: [Float] = [0, 0, 0, 0]
let writer = storage.withUnsafeMutableBytes { bytes in
    FrameWriter(format: .real(count: 4), delivery: nil, first: bytes.baseAddress, second: nil, capacity: 4, channelCount: 1, counter: &counter, inputTime: 0)
}
