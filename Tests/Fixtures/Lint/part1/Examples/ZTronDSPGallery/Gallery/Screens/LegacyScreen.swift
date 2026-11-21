// The gallery's application is SwiftUI alone: the UIKit boundary holds here, with no bridge.
import SwiftUI
import UIKit                                            // !! UB-1

struct LegacyScreen: View {
    let haptics = UIImpactFeedbackGenerator()           // !! UB-2
    let alignment: NSTextAlignment = .center            // !! UB-2
    var body: some View { Text("UIView in a string is not a name") }
}
