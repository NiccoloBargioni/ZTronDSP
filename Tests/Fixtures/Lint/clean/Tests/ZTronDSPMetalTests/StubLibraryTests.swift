import Metal

// A test may compile a shader from source: DEP-4 binds the production code under Sources/ only.
func stubLibrary(on device: any MTLDevice) throws -> any MTLLibrary {
    try device.makeLibrary(source: "kernel void ztd_stub(uint id [[thread_position_in_grid]]) {}", options: nil)
}
