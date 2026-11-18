/// A node: a `while` loop where a `for … in` loop would allocate in Debug builds (CR-002).
final class CentroidNode {
    func process(_ bins: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0
        var index = 0
        while index < bins.count {
            sum += Float(index) * bins[index]
            index += 1
        }
        return sum
    }
}
