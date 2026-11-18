// expect: A block cannot begin with OnsetStrength: its domains depend on the stage before it.
//
// O-12, ORD-3: a pipeline begins with a self-typed stage or a sequence stage; a source delivers
// samples, and there is no spectrum before the first line.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { OnsetStrength(); Tempogram() }
