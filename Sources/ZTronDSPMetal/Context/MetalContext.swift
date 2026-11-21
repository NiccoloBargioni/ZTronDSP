import Foundation
import Metal
import ZTronDSPCore

/// What a Metal device can do, as far as the package cares (WP-601). The figures are read from
/// the device or measured on it when a ``MetalContext`` is created; nothing is assumed.
///
/// An immutable value, usable on any thread; it does not allocate.
public struct MetalCapabilities: Hashable, Sendable {
    /// The device's name, as Metal reports it.
    public let deviceName: String
    /// The largest width or height a two-dimensional texture may have. Metal has no query for
    /// it: it is 16 384 from the Apple3 GPU family up and 8 192 below.
    public let maximumTextureDimension: Int
    /// The largest buffer the device allocates, in bytes.
    public let maximumBufferLength: Int
    /// Whether a sampler set to linear filtering interpolates a half-float texture
    /// (`r16Float`, `rg16Float`). Measured by drawing one. The package's own shaders read
    /// texels and interpolate themselves, so they do not depend on it.
    public let filtersHalfFloatLinearly: Bool
    /// Whether the device filters 32-bit float textures.
    public let filtersFloatLinearly: Bool
    /// The device's tier of read-write textures in compute functions: 0 (none), 1 or 2.
    public let readWriteTextureTier: Int
    /// Whether the processor and the GPU share their memory.
    public let hasUnifiedMemory: Bool
}

/// The Metal device the package draws and computes with, its command queue, the shader
/// library and what the device can do (WP-601).
///
/// The shaders travel in the module bundle as sources and are compiled when a context is
/// created (change request CR-011). That takes from some milliseconds to seconds, so a
/// context is made off the main thread: ``shared()`` does that and keeps the result for the
/// life of the process.
///
/// ```swift
/// let context = try await MetalContext.shared()
/// let renderer = try HeatmapRenderer(context: context, feed: feed)
/// ```
///
/// Threading: a context is immutable and `Sendable`; its device, queue, library and pipeline
/// states may be used from any thread. Creating one allocates, compiles shaders and draws
/// once: not for the main thread, never for the analysis thread.
public final class MetalContext: Sendable {
    /// The GPU.
    public let device: any MTLDevice
    /// The queue every command buffer of the package goes through, in the order it was
    /// committed.
    public let commandQueue: any MTLCommandQueue
    /// The package's shaders, compiled for `device`.
    public let library: any MTLLibrary
    /// What `device` can do.
    public let capabilities: MetalCapabilities

    /// The pipeline states every renderer and kernel of the package uses, built once here so
    /// that no renderer compiles one on the main thread.
    let pipelines: PipelineStates

    /// A context on `device`.
    ///
    /// Pass `MTLCreateSystemDefaultDevice()`: where there is no GPU that function returns
    /// `nil`, and so does this initialiser's argument.
    ///
    /// Compiles the shaders and measures the device: call it off the main thread, or use
    /// ``shared()``.
    ///
    /// - Throws: `backendUnavailable` for an absent device, for a device that gives no command
    ///   queue, and when the shaders do not compile on it.
    public convenience init(device: (any MTLDevice)?) throws(DSPError) {
        try self.init(device: device, shaderSource: try ShaderSources.bundled())
    }

    /// A context whose library is compiled from `shaderSource`: the seam for the test of a
    /// source that does not compile. `textureLimit` lowers the largest texture the context
    /// permits below the device's, so that tests reach the paths for data no texture fits
    /// without allocating such data.
    init(device: (any MTLDevice)?, shaderSource: String, textureLimit: Int? = nil) throws(DSPError) {
        guard let device else {
            throw .backendUnavailable(reason: "this system has no Metal device")
        }
        guard let queue = device.makeCommandQueue() else { throw .backendUnavailable(reason: "the Metal device \(device.name) gives no command queue") }
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw .backendUnavailable(reason: "the shaders do not compile on \(device.name): \(error.localizedDescription)")
        }
        let pipelines = try PipelineStates(device: device, library: library)
        self.device = device
        self.commandQueue = queue
        self.library = library
        self.pipelines = pipelines
        capabilities = MetalCapabilities(
            deviceName: device.name,
            maximumTextureDimension: min(device.supportsFamily(.apple3) ? 16_384 : 8_192, max(textureLimit ?? Int.max, 1)),
            maximumBufferLength: device.maxBufferLength,
            filtersHalfFloatLinearly: HalfFloatFilterProbe.measure(device: device, queue: queue, pipeline: pipelines.probe),
            filtersFloatLinearly: device.supports32BitFloatFiltering,
            readWriteTextureTier: Int(device.readWriteTextureSupport.rawValue),
            hasUnifiedMemory: device.hasUnifiedMemory)
    }

    /// Made on first use, by whichever thread asks first; Swift makes that happen once.
    private static let common: Result<MetalContext, DSPError> = Result { () throws(DSPError) -> MetalContext in
        try MetalContext(device: MTLCreateSystemDefaultDevice())
    }

    /// The context on the system's default device, made once per process on the background
    /// executor (BG-1) and shared from then on.
    ///
    /// May be called from any context, the main actor included: the caller suspends while the
    /// shaders compile the first time, and for a hop to the background executor afterwards.
    ///
    /// - Throws: `backendUnavailable` where there is no Metal device, every time it is asked;
    ///   `cancelled` when the calling task was cancelled.
    public static func shared() async throws(DSPError) -> MetalContext {
        try await BackgroundWork.run { _ throws(DSPError) -> MetalContext in try common.get() }
    }

    /// The same context for code that already runs off the main thread, such as a strategy
    /// inside background work. The first call blocks while the shaders compile; never call it
    /// on the main thread or on the analysis thread.
    ///
    /// - Throws: `backendUnavailable` where there is no Metal device.
    public static func sharedBlocking() throws(DSPError) -> MetalContext {
        try common.get()
    }

    /// Whether a texture of this size can be made on the device. Metal stops the process on a
    /// texture that is too large, so everything that sizes a texture by data asks first.
    func permits(width: Int, height: Int) -> Bool {
        width >= 1 && height >= 1 && width <= capabilities.maximumTextureDimension && height <= capabilities.maximumTextureDimension
    }
}

/// The shader sources of the module bundle (CR-011).
enum ShaderSources {
    /// The sources that travel in the module bundle.
    static func bundled() throws(DSPError) -> String {
        try load(from: Bundle.module.url(forResource: "Shaders", withExtension: nil))
    }

    /// Every `.metal` file of `folder`, in the order of their names, as one source:
    /// `Common.metal` comes first and the others build on it. A file that cannot be read is
    /// left out; what it defined is then missing from the library, which says so.
    static func load(from folder: URL?) throws(DSPError) -> String {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            throw .backendUnavailable(reason: "the shader sources are missing from the module bundle")
        }
        var source = ""
        for name in names.sorted() where name.hasSuffix(".metal") {
            let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            source += "// ===== \(name) =====\n" + text + "\n"
        }
        return source
    }
}

/// The calls that give nothing back only when the system is out of memory or the device is
/// lost, each in one place, so that every caller's failure reads the same.
enum MetalResources {
    /// A texture of `shape` whose texels the processor can read and write.
    static func texture(_ shape: MTLTextureDescriptor, on device: any MTLDevice, what: String) throws(DSPError) -> any MTLTexture {
        shape.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: shape) else { throw .resourceAllocationFailed(what: what) }
        return texture
    }

    static func commands(on queue: any MTLCommandQueue) throws(DSPError) -> any MTLCommandBuffer {
        guard let commands = queue.makeCommandBuffer() else { throw .resourceAllocationFailed(what: "a command buffer") }
        return commands
    }

    /// Commits `commands` and waits until the device has run them. Blocks.
    static func finish(_ commands: any MTLCommandBuffer, what: String) throws(DSPError) {
        commands.commit()
        commands.waitUntilCompleted()
        let reason = commands.error?.localizedDescription ?? "no reason given"
        guard commands.status == .completed else { throw .backendUnavailable(reason: "the Metal device did not finish \(what): \(reason)") }
    }

    /// One render pass that draws the screen triangle with `pipeline`: one draw call, no vertex
    /// buffer (§8.2). `bind` sets what the fragment function reads.
    static func drawScreen(
        with pipeline: any MTLRenderPipelineState, to pass: MTLRenderPassDescriptor, in commands: any MTLCommandBuffer,
        bind: (any MTLRenderCommandEncoder) -> Void
    ) {
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        bind(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

/// The package's pipeline states, by what they draw or compute.
struct PipelineStates: Sendable {
    /// The pixel formats the render pipelines are built for up front: what a Metal view
    /// presents by default, and what an off-screen target and a snapshot image use.
    static let prebuiltFormats: [MTLPixelFormat] = [.bgra8Unorm, .rgba8Unorm]

    let heatmap: [MTLPixelFormat: any MTLRenderPipelineState]
    let waveform: [MTLPixelFormat: any MTLRenderPipelineState]
    let probe: any MTLRenderPipelineState
    let median: any MTLComputePipelineState

    init(device: any MTLDevice, library: any MTLLibrary) throws(DSPError) {
        var heatmap: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
        var waveform: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
        for format in Self.prebuiltFormats {
            heatmap[format] = try Self.render(device, library, fragment: "ztd_heatmap_fragment", format: format)
            waveform[format] = try Self.render(device, library, fragment: "ztd_waveform_fragment", format: format)
        }
        self.heatmap = heatmap
        self.waveform = waveform
        probe = try Self.render(device, library, fragment: "ztd_probe_fragment", format: .rgba8Unorm)
        guard let function = library.makeFunction(name: "ztd_median_kernel"),
              let median = try? device.makeComputePipelineState(function: function)
        else {
            throw .backendUnavailable(reason: "the shader library has no usable function ztd_median_kernel")
        }
        self.median = median
    }

    /// A render pipeline that draws the screen triangle with `fragment` into `format`.
    static func render(
        _ device: any MTLDevice, _ library: any MTLLibrary, fragment: String, format: MTLPixelFormat
    ) throws(DSPError) -> any MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: "ztd_screen_vertex"),
              let fragmentFunction = library.makeFunction(name: fragment)
        else {
            throw .backendUnavailable(reason: "the shader library has no function \(fragment)")
        }
        let description = MTLRenderPipelineDescriptor()
        description.label = fragment
        description.vertexFunction = vertexFunction
        description.fragmentFunction = fragmentFunction
        description.colorAttachments[0].pixelFormat = format
        // A format no target can have. Under Metal's validation, which a test run has on, the
        // process stops before this error is reported; an app without validation gets it.
        do { return try device.makeRenderPipelineState(descriptor: description) }
        catch { throw .backendUnavailable(reason: "no pipeline for \(fragment) in the pixel format \(format.rawValue): \(error.localizedDescription)") }
    }
}

extension MetalContext {
    /// The heat-map pipeline for a target of `format`: the one built with the context, or a
    /// new one for a format the context was not built for.
    func heatmapPipeline(for format: MTLPixelFormat) throws(DSPError) -> any MTLRenderPipelineState {
        if let state = pipelines.heatmap[format] { return state }
        return try PipelineStates.render(device, library, fragment: "ztd_heatmap_fragment", format: format)
    }

    /// The waveform pipeline for a target of `format`.
    func waveformPipeline(for format: MTLPixelFormat) throws(DSPError) -> any MTLRenderPipelineState {
        if let state = pipelines.waveform[format] { return state }
        return try PipelineStates.render(device, library, fragment: "ztd_waveform_fragment", format: format)
    }
}

/// The measurement behind `MetalCapabilities.filtersHalfFloatLinearly`: a texture of two
/// texels, 0 and 1, drawn eight fragments wide through a linear sampler.
enum HalfFloatFilterProbe {
    /// What the eight fragments came out as, 0 … 255.
    static func draw(device: any MTLDevice, queue: any MTLCommandQueue, pipeline: any MTLRenderPipelineState) throws(DSPError) -> [UInt8] {
        let sourceShape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 2, height: 1, mipmapped: false)
        sourceShape.usage = .shaderRead
        let targetShape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 1, mipmapped: false)
        targetShape.usage = [.renderTarget, .shaderRead]
        let source = try MetalResources.texture(sourceShape, on: device, what: "a probe texture")
        let target = try MetalResources.texture(targetShape, on: device, what: "a probe target")
        // 0 and 1 as half floats.
        var texels: [UInt16] = [0x0000, 0x3C00]
        source.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: &texels, bytesPerRow: 4)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let commands = try MetalResources.commands(on: queue)
        MetalResources.drawScreen(with: pipeline, to: pass, in: commands) { $0.setFragmentTexture(source, index: 0) }
        try MetalResources.finish(commands, what: "the filtering probe")
        var pixels = [UInt8](repeating: 0, count: 32)
        target.getBytes(&pixels, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 8, 1), mipmapLevel: 0)
        return stride(from: 0, to: 32, by: 4).map { pixels[$0] }
    }

    /// True when the fragments between the two texel centres came out in between the texels'
    /// values. Without filtering the row is four fragments of 0 and four of 255.
    static func isInterpolated(_ row: [UInt8]) -> Bool {
        row.count == 8 && row[3] > 16 && row[3] < 128 && row[4] > 128 && row[4] < 240
    }

    /// The flag: false also where the device would not draw.
    static func measure(device: any MTLDevice, queue: any MTLCommandQueue, pipeline: any MTLRenderPipelineState) -> Bool {
        ((try? draw(device: device, queue: queue, pipeline: pipeline)).map(isInterpolated)) ?? false
    }
}
