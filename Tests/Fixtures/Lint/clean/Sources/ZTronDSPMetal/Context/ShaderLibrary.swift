import Metal

// The library the build compiled into the module bundle, loaded on a device (DEP-4). Nothing here
// calls `makeLibrary(source:options:)`; this comment and the string below may name it.
enum ShaderLibrary {
    static let refused = "makeLibrary(source:options:) is not used"

    static func load(from bundle: Bundle, on device: any MTLDevice) throws -> any MTLLibrary {
        try device.makeDefaultLibrary(bundle: bundle)
    }
}
