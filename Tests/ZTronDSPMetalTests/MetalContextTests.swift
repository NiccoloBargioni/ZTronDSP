import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// `MetalContext` (WP-601): device, queue, the library the build compiled into the module bundle
/// (DEP-4), capability flags.
@Suite("MetalContext")
struct MetalContextTests {
    @Test func theSharedContextWorksOnTheSimulator() async throws {
        let start = Benchmark.ticks()
        let context = try await MetalContext.shared()
        let elapsed = Benchmark.nanoseconds(Benchmark.ticks() &- start) / 1e6
        print("MetalContext.shared(): \(elapsed) ms, the first call makes the context (loads the library, builds the pipelines, measures the device); \(context.capabilities)")

        #expect(!context.device.name.isEmpty && context.capabilities.deviceName == context.device.name)
        for function in ShaderFunction.allCases {
            #expect(context.library.functionNames.contains(function.rawValue), "the library holds \(function.rawValue)")
        }
        #expect(context.pipelines.heatmap.count == 2 && context.pipelines.waveform.count == 2, "a pipeline per format a view and an image use")
        #expect(context.pipelines.heatmap[.bgra8Unorm] != nil && context.pipelines.heatmap[.rgba8Unorm] != nil)

        // The same context from then on, from either door.
        let again = try await MetalContext.shared()
        let blocking = try MetalContext.sharedBlocking()
        #expect(again === context && blocking === context)
        context.waitUntilIdle()
    }

    @Test func anAbsentDeviceIsBackendUnavailable() {
        // What MTLCreateSystemDefaultDevice() returns where there is no GPU.
        let nothing: (any MTLDevice)? = nil
        #expect(throws: DSPError.backendUnavailable(reason: "this system has no Metal device")) { try MetalContext(device: nothing) }
        do throws(DSPError) {
            _ = try MetalContext(device: nothing)
            Issue.record("a context was made without a device")
        } catch {
            #expect(error.description.contains("backend is unavailable"), "the error says which backend: \(error)")
        }
    }

    /// DEP-4: the build compiles the `.metal` sources into `default.metallib`; what travels in the
    /// module bundle is that library, and no source of it.
    @Test func theModuleBundleHoldsTheCompiledLibraryAndNoShaderSource() throws {
        let bundle = ShaderLibrary.bundle
        let files = try #require(FileManager.default.subpaths(atPath: bundle.bundlePath), "the module bundle at \(bundle.bundlePath) can be listed")
        #expect(files.contains("default.metallib"), "the build put default.metallib in \(bundle.bundleURL.lastPathComponent): \(files.sorted())")
        let sources = files.filter { path in
            ["metal", "h", "air"].contains(URL(fileURLWithPath: path).pathExtension) || path.split(separator: "/").contains("Shaders")
        }
        #expect(sources.isEmpty, "no shader source travels in the module bundle: \(sources.sorted())")
    }

    /// One list, compared both ways: every function a pipeline asks for is in the library, and
    /// the library holds no function that no pipeline asks for.
    @Test func theLibraryHoldsExactlyTheFunctionsThePipelinesAskFor() async throws {
        let context = try await sharedContext()
        let mismatch = functionMismatch(of: context.library)
        #expect(mismatch.missing.isEmpty, "asked for by a pipeline and missing from the library: \(mismatch.missing)")
        #expect(mismatch.unused.isEmpty, "compiled into the library and asked for by no pipeline: \(mismatch.unused)")
        #expect(context.library.functionNames.count == ShaderFunction.allCases.count, "\(context.library.functionNames.sorted())")

        // The comparison sees either difference.
        let device = context.device
        let short = functionMismatch(of: try stubLibrary(on: device, with: ShaderFunction.allCases.filter { $0 != .probeFragment }))
        #expect(short.missing == ["ztd_probe_fragment"] && short.unused.isEmpty, "\(short)")
        let long = functionMismatch(of: try stubLibrary(on: device, with: ShaderFunction.allCases, extra: ["ztd_unused_kernel"]))
        #expect(long.missing.isEmpty && long.unused == ["ztd_unused_kernel"], "\(long)")

        // Every function of the list is asked for: a library without it makes no context, and the
        // error names the function that is missing, not another one.
        for function in ShaderFunction.allCases {
            let lacking = try stubLibrary(on: device, with: ShaderFunction.allCases.filter { $0 != function })
            do throws(DSPError) {
                _ = try MetalContext(device: device, library: lacking)
                Issue.record("a context was made from a library without \(function.rawValue)")
            } catch {
                #expect(error == .backendUnavailable(reason: "the shader library has no function \(function.rawValue)"), "\(error)")
            }
        }
    }

    @Test func aBundleWithoutTheLibraryIsBackendUnavailable() async throws {
        let device = try await sharedContext().device
        // The test bundle holds golden images and no default.metallib.
        do throws(DSPError) {
            _ = try ShaderLibrary.load(from: Bundle.module, on: device)
            Issue.record("a library was loaded from a bundle that holds none")
        } catch {
            guard case .backendUnavailable(let reason, _) = error else {
                Issue.record("another error: \(error)")
                return
            }
            #expect(reason.contains("no shader library default.metallib in \(Bundle.module.bundleURL.lastPathComponent)"), "\(reason)")
        }
        // A library with none of the functions: the first one asked for is named.
        let empty = try stubLibrary(on: device, with: [])
        #expect(throws: DSPError.backendUnavailable(reason: "the shader library has no function ztd_screen_vertex")) {
            try MetalContext(device: device, library: empty)
        }
    }

    @Test func makingTheSharedContextIsBackgroundWork() async {
        // A task that is already cancelled never starts background work (BG-3): the shared
        // context goes through the background executor even when it exists.
        let task = Task { () async throws -> MetalContext in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MetalContext.shared()
        }
        let result = await task.result
        #expect(result.isCancelled)
    }

    @Test func capabilitiesAreMeasuredOrReadFromTheDevice() async throws {
        let context = try await sharedContext()
        let capabilities = context.capabilities
        #expect(capabilities.maximumTextureDimension == (context.device.supportsFamily(.apple3) ? 16_384 : 8_192))
        #expect(capabilities.maximumBufferLength == context.device.maxBufferLength && capabilities.maximumBufferLength > 0)
        #expect(capabilities.filtersFloatLinearly == context.device.supports32BitFloatFiltering)
        #expect((0 ... 2).contains(capabilities.readWriteTextureTier))
        #expect(capabilities.hasUnifiedMemory == context.device.hasUnifiedMemory)
        #expect(context.permits(width: capabilities.maximumTextureDimension, height: 1) && !context.permits(width: capabilities.maximumTextureDimension + 1, height: 1))
        #expect(!context.permits(width: 0, height: 4) && !context.permits(width: 4, height: 0))

        // The largest texture the flag promises can be made (a larger one stops the process).
        let shape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: capabilities.maximumTextureDimension, height: 2, mipmapped: false)
        #expect(context.device.makeTexture(descriptor: shape) != nil)
    }

    /// WP-604: "a sampler test records whether half-float textures filter linearly".
    @Test func aSamplerTestRecordsWhetherHalfFloatTexturesFilterLinearly() async throws {
        let context = try await sharedContext()
        let row = try HalfFloatFilterProbe.draw(device: context.device, queue: context.commandQueue, pipeline: context.pipelines.probe)
        print("r16Float through a linear sampler, texels 0 and 1 over eight fragments: \(row); filtersHalfFloatLinearly = \(context.capabilities.filtersHalfFloatLinearly)")
        #expect(row.count == 8 && row[0] == 0 && row[7] == 255, "the ends are the two texels")
        #expect(context.capabilities.filtersHalfFloatLinearly == HalfFloatFilterProbe.isInterpolated(row), "the flag is the measurement")
        // What the measurement tells apart.
        #expect(HalfFloatFilterProbe.isInterpolated([0, 0, 32, 96, 159, 223, 255, 255]), "a ramp between the texel centres")
        #expect(!HalfFloatFilterProbe.isInterpolated([0, 0, 0, 0, 255, 255, 255, 255]), "nearest: two flat halves")
        #expect(!HalfFloatFilterProbe.isInterpolated([0, 0, 0]) && !HalfFloatFilterProbe.isInterpolated([]))
        if context.capabilities.filtersHalfFloatLinearly {
            #expect(zip(row, row.dropFirst()).allSatisfy { $0 <= $1 }, "a filtered row rises from one texel to the other")
        }
    }

    @Test func pipelinesForOtherFormatsAreBuiltOnDemand() async throws {
        let context = try await sharedContext()
        // A format the context was not built for.
        #expect(context.pipelines.heatmap[.bgra8Unorm_srgb] == nil)
        _ = try context.heatmapPipeline(for: .bgra8Unorm_srgb)
        _ = try context.waveformPipeline(for: .bgra8Unorm_srgb)
        // The ones it was built for are handed out, not built again.
        #expect(try context.heatmapPipeline(for: .bgra8Unorm) === context.pipelines.heatmap[.bgra8Unorm])
        #expect(try context.waveformPipeline(for: .rgba8Unorm) === context.pipelines.waveform[.rgba8Unorm])
        // A library without the fragment gives no pipeline, and says which function it lacks.
        let lacking = try stubLibrary(on: context.device, with: [.screenVertex])
        #expect(throws: DSPError.backendUnavailable(reason: "the shader library has no function ztd_heatmap_fragment")) {
            _ = try PipelineStates.render(context.device, lacking, fragment: .heatmapFragment, format: .rgba8Unorm)
        }
    }

    @Test func aContextCanBeHeldToSmallerTextures() async throws {
        // The seam the tests of data too large for a texture use.
        let shared = try await sharedContext()
        let limited = try MetalContext(device: shared.device, library: shared.library, textureLimit: 64)
        #expect(limited.capabilities.maximumTextureDimension == 64 && limited.permits(width: 64, height: 64) && !limited.permits(width: 65, height: 1))
        #expect(try MetalContext(device: shared.device, library: shared.library, textureLimit: 1 << 20).capabilities.maximumTextureDimension
            == shared.capabilities.maximumTextureDimension, "never above the device's")
        #expect(try MetalContext(device: shared.device, library: shared.library, textureLimit: 0).capabilities.maximumTextureDimension == 1)
    }
}

/// The two ways a library and the list the pipelines ask through can differ: functions asked for
/// that the library lacks, and functions the library holds that nothing asks for.
func functionMismatch(of library: any MTLLibrary) -> (missing: [String], unused: [String]) {
    let compiled = Set(library.functionNames)
    let asked = Set(ShaderFunction.allCases.map(\.rawValue))
    return (asked.subtracting(compiled).sorted(), compiled.subtracting(asked).sorted())
}

/// A library compiled here, in the test, from a source with a function of the right kind for each
/// of `functions` and a kernel for each name of `extra`: what a library that lacks a function, or
/// holds one no pipeline uses, is to a context. The package itself compiles no shader source
/// (DEP-4); a test may.
func stubLibrary(on device: any MTLDevice, with functions: [ShaderFunction], extra: [String] = []) throws -> any MTLLibrary {
    var source = "#include <metal_stdlib>\nusing namespace metal;\nstruct StubVertex { float4 position [[position]]; };\n"
    for function in functions {
        switch function {
        case .screenVertex:
            source += "vertex StubVertex \(function.rawValue)(uint id [[vertex_id]]) { StubVertex out; out.position = float4(0.0, 0.0, 0.0, 1.0); return out; }\n"
        case .heatmapFragment, .waveformFragment, .probeFragment:
            source += "fragment float4 \(function.rawValue)() { return float4(0.0); }\n"
        case .medianKernel:
            source += "kernel void \(function.rawValue)(uint id [[thread_position_in_grid]]) {}\n"
        }
    }
    for name in extra { source += "kernel void \(name)(uint id [[thread_position_in_grid]]) {}\n" }
    return try device.makeLibrary(source: source, options: nil)
}

extension Result {
    /// True for the failure `DSPError.cancelled`.
    var isCancelled: Bool {
        if case .failure(let error) = self, let known = error as? DSPError { return known == .cancelled }
        return false
    }
}
