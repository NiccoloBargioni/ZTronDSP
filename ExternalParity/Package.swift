// swift-tools-version: 6.2
import PackageDescription

// ExternalParity — the external parity suite and the examples of the extension guide
// (specification §5.11, EXT-4; WP-907, WP-908).
//
// A package outside ZTronDSP that depends on it by path and on its three products only:
// `ZTronDSP`, `ZTronDSPUI` (only where an example needs a view) and `ZTronDSPTesting`. Nothing
// here uses `@testable import`, `@_spi`, `package` access or an internal symbol of ZTronDSP:
// what cannot be done through its `public` API is a finding, not something to work around.
//
//   CExternalKernels     C11. The biquad cascade the external low-pass runs on: a `ztd_kernel_t`
//                        of the caller's own (§5.11.1).
//   ExternalStages       The three stock stages re-implemented (EXT-4): `ExternalGain` as a
//                        `SampleProcessor`, `ExternalLowPass` on the C kernel, `ExternalMelScale`
//                        as a step family with its node.
//   CExtensionGuide      C11. The kernel of the guide's "sample-domain stage in C".
//   ExtensionGuide       One example per row of §5.11.1 (Docs/ExtensionGuide.md shows their code).
//   ExtensionGuideUI     The one example that needs a view: the display.
//   ExternalTestSupport  What the two test targets share (under Tests/).
//
// Built and tested with `xcodebuild` against an iOS simulator, as ZTronDSP is (DEP-4):
// Scripts/external-parity.sh of the main package drives it.

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

// RT-1, RT-7(1): a `nonblocking` function that allocates, or calls a function that is not itself
// `nonblocking`, does not build. The same two settings as the main manifest.
// snippet:begin manifest-kernel-settings
let kernelSettings: [CSetting] = [
    .enableWarning("function-effects"),
    .treatWarning("function-effects", as: .error),
]
// snippet:end manifest-kernel-settings

let package = Package(
    name: "ExternalParity",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ExternalStages", targets: ["ExternalStages"]),
        .library(name: "ExtensionGuide", targets: ["ExtensionGuide"]),
        .library(name: "ExtensionGuideUI", targets: ["ExtensionGuideUI"]),
    ],
    // snippet:begin manifest-dependency
    dependencies: [
        .package(name: "ZTronDSP", path: ".."),
    ],
    // snippet:end manifest-dependency
    targets: [
        // MARK: The parity suite (WP-907)

        .target(
            name: "CExternalKernels",
            dependencies: [.product(name: "ZTronDSP", package: "ZTronDSP")],
            cSettings: kernelSettings,
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(
            name: "ExternalStages",
            dependencies: ["CExternalKernels", .product(name: "ZTronDSP", package: "ZTronDSP")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ExternalStagesTests",
            dependencies: [
                "ExternalStages", "CExternalKernels", "ExternalTestSupport",
                .product(name: "ZTronDSP", package: "ZTronDSP"),
                .product(name: "ZTronDSPTesting", package: "ZTronDSP"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: What the two test targets share

        // A sink that collects, a source fed by hand, the audit on an engine's thread: written on
        // the public API like everything else here. A regular target, because two test targets
        // cannot share a file; it lives under Tests/ and is linked into nothing but tests.
        .target(
            name: "ExternalTestSupport",
            dependencies: [
                .product(name: "ZTronDSP", package: "ZTronDSP"),
                .product(name: "ZTronDSPTesting", package: "ZTronDSP"),
            ],
            path: "Tests/ExternalTestSupport",
            swiftSettings: swiftSettings
        ),

        // MARK: The extension guide (WP-908)

        // snippet:begin manifest-targets
        .target(
            name: "CExtensionGuide",
            dependencies: [.product(name: "ZTronDSP", package: "ZTronDSP")],
            cSettings: kernelSettings
        ),
        .target(
            name: "ExtensionGuide",
            dependencies: ["CExtensionGuide", .product(name: "ZTronDSP", package: "ZTronDSP")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ExtensionGuideUI",
            dependencies: [
                "ExtensionGuide",
                .product(name: "ZTronDSP", package: "ZTronDSP"),
                .product(name: "ZTronDSPUI", package: "ZTronDSP"),
            ],
            swiftSettings: swiftSettings
        ),
        // snippet:end manifest-targets
        .testTarget(
            name: "ExtensionGuideTests",
            dependencies: [
                "ExtensionGuide", "ExtensionGuideUI", "CExtensionGuide", "ExternalTestSupport",
                .product(name: "ZTronDSP", package: "ZTronDSP"),
                .product(name: "ZTronDSPUI", package: "ZTronDSP"),
                .product(name: "ZTronDSPTesting", package: "ZTronDSP"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    cLanguageStandard: .c11
)
