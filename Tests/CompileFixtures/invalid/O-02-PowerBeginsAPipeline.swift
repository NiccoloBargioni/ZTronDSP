// expect: A block cannot begin with Power: its domains depend on the stage before it.
//
// ORD-3, O-2: a pipeline begins with a self-typed stage or a sequence stage; there is no
// spectrum before its first line.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { Power(); Decibels() }
