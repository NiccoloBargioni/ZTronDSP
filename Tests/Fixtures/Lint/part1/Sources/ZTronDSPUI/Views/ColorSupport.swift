import SwiftUI
import UIKit                                   // !! UB-1
@preconcurrency import AppKit                  // !! UB-1
import class UIKit.UIColor                     // !! UB-1
#if canImport(UIKit)                           // !! UB-2
let scale = UIScreen.main.scale                // !! UB-2
#endif
func tint() -> UIColor { UIImage() as Any as! UIColor }    // !! UB-2 UB-2
let alignment: NSTextAlignment = .center       // !! UB-2
let constraint = NSLayoutConstraint()          // !! UB-2
let width: UInt32 = 4                          // UInt32 is not a UIKit name
let name = "UIView in a string"                // nor is a string
let host: MTKView? = nil                       // !! UB-2
