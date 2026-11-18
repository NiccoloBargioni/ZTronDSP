import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// `MetalContext` (WP-601): device, queue, the library compiled from the bundled sources
/// (CR-011), capability flags.
@Suite("MetalContext")
struct MetalContextTests {
    @Test func theSharedContextWorksOnTheSimulator() async throws {
        let start = Benchmark.ticks()
        let context = try await MetalContext.shared()
        let elapsed = Benchmark.nanoseconds(Benchmark.ticks() &- start) / 1e6
        print("MetalContext.shared(): \(elapsed) ms, the first call compiles the shaders; \(context.capabilities)")

        #expect(!context.device.name.isEmpty && context.capabilities.deviceName == context.device.name)
        for name in ["ztd_screen_vertex", "ztd_heatmap_fragment", "ztd_waveform_fragment", "ztd_median_kernel", "ztd_probe_fragment"] {
            #expect(context.library.functionNames.contains(name), "the library holds \(name)")
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
            _ = try MetalContext(device: nothing, shaderSource: "")
            Issue.record("a context was made without a device")
        } catch {
            #expect(error.description.contains("backend is unavailable"), "the error says which backend: \(error)")
        }
    }

    @Test func shadersThatDoNotCompileAreBackendUnavailable() async throws {
        let device = try await MetalContext.shared().device
        func reason(_ source: String) -> String? {
            do throws(DSPError) {
                _ = try MetalContext(device: device, shaderSource: source)
                return nil
            } catch {
                if case .backendUnavailable(let reason, _) = error { return reason }
                return "another error: \(error)"
            }
        }
        let broken = reason("this is not the Metal shading language")
        #expect(broken?.contains("do not compile") == true, "\(broken ?? "a context was made")")
        // A library that compiles and lacks what the package draws with.
        let incomplete = reason("#include <metal_stdlib>\nusing namespace metal;\nstatic float unused(float x) { return x; }\n")
        #expect(incomplete?.contains("ztd_heatmap_fragment") == true, "\(incomplete ?? "a context was made")")
        // The screen vertex and the fragments are there, the median kernel is not.
        let bundled = try ShaderSources.bundled()
        let withoutKernel = reason(bundled.replacingOccurrences(of: "ztd_median_kernel", with: "ztd_other_kernel"))
        #expect(withoutKernel?.contains("ztd_median_kernel") == true, "\(withoutKernel ?? "a context was made")")
    }

    @Test func theBundledSourcesAreEveryShaderFileInOrder() throws {
        // No folder, or a folder that is not there: no sources, said plainly.
        #expect(throws: DSPError.self) { try ShaderSources.load(from: nil) }
        #expect(throws: DSPError.self) { try ShaderSources.load(from: URL(fileURLWithPath: "/no/such/folder/of/shaders")) }
        let source = try ShaderSources.bundled()
        let markers = ["Common.metal", "Heatmap.metal", "Median.metal", "Probe.metal", "Waveform.metal"].map { "// ===== \($0) =====" }
        let positions = markers.compactMap { source.range(of: $0)?.lowerBound }
        #expect(positions.count == markers.count, "every file is in the bundle")
        #expect(positions == positions.sorted(), "Common.metal first: the others use what it declares")
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
        #expect(throws: DSPError.self) {
            _ = try PipelineStates.render(context.device, context.library, fragment: "ztd_no_such_fragment", format: .rgba8Unorm)
        }
    }

    @Test func aContextCanBeHeldToSmallerTextures() async throws {
        // The seam the tests of data too large for a texture use.
        let shared = try await sharedContext()
        let limited = try MetalContext(device: shared.device, shaderSource: try ShaderSources.bundled(), textureLimit: 64)
        #expect(limited.capabilities.maximumTextureDimension == 64 && limited.permits(width: 64, height: 64) && !limited.permits(width: 65, height: 1))
        #expect(try MetalContext(device: shared.device, shaderSource: try ShaderSources.bundled(), textureLimit: 1 << 20).capabilities.maximumTextureDimension
            == shared.capabilities.maximumTextureDimension, "never above the device's")
        #expect(try MetalContext(device: shared.device, shaderSource: try ShaderSources.bundled(), textureLimit: 0).capabilities.maximumTextureDimension == 1)
    }
}

extension Result {
    /// True for the failure `DSPError.cancelled`.
    var isCancelled: Bool {
        if case .failure(let error) = self, let known = error as? DSPError { return known == .cancelled }
        return false
    }
}
