import QuartzCore

// The drawable is sized by the display scale SwiftUI reports. A comment may name the layer's
// contentsScale; the code does not (SZ-2).
func drawableScale(of layer: CALayer, display: Double) -> Double {
    let read = Double(layer.contentsScale)              // !! SZ-2
    return display > 0 ? display : read
}
let note = "contentsScale in a string is not code"
