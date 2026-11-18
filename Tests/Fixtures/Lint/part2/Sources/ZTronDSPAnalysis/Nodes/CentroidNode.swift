final class CentroidNode {
    func process(_ bins: [Float]) -> Float {
        var sum: Float = 0
        for (index, value) in bins.enumerated() where value > 0 {   // !! RT-7
            sum += Float(index) * value
        }
        return sum
    }
}
