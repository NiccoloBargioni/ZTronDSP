// expect: extra argument 'values' in call
//
// FINDING. The kernel ABI gives every kernel a command for new values (ZTD_COMMAND_SET_VALUES), and the engine sends it to the stock specs only: a CustomKernel has no place to state its values apart from its key, so a changed value is another kernel (§5.5.4). This fixture fails the day CustomKernel takes its values.
import ExternalStages
import SwiftUI
import ZTronDSP

let kernel = CustomKernel(name: "Comb", key: 480, values: [0.5], make: { _, _, _ in ztd_kernel_identity() })
