import Metal

// A shader library compiled from source while the package runs, which DEP-4 forbids in production
// code: the build compiles the shaders. A comment may name `device.makeLibrary(source: text, options: nil)`.
enum RuntimeShaders {
    static let note = "device.makeLibrary(source: text, options: nil) is named in a string, not called"

    static func compiled(_ text: String, on device: any MTLDevice) throws -> any MTLLibrary {
        try device.makeLibrary(source: text, options: nil)                                   // !! DEP-4
    }

    static func compiledLater(_ text: String, on device: any MTLDevice) {
        device.makeLibrary(source: text, options: MTLCompileOptions()) { _, _ in }           // !! DEP-4
    }

    static func split(_ text: String, on device: any MTLDevice) throws -> any MTLLibrary {
        try device
            .makeLibrary(                                                                    // !! DEP-4
                source: text, options: nil)
    }

    static func bundled(on device: any MTLDevice) throws -> any MTLLibrary {
        try device.makeDefaultLibrary(bundle: .main)
    }

    static func fromData(_ data: DispatchData, on device: any MTLDevice) throws -> any MTLLibrary {
        try device.makeLibrary(data: data)
    }
}
