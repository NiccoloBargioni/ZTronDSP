// swift-tools-version: 6.2
import PackageDescription

// ZTronDSP — real-time audio DSP behind one declarative facade (specification §4.2).
//
// Targets, top to bottom, in the order of the dependency rule DEP-1: a target imports only
// targets declared above it.
//
//   CZTronDSP          C11 / Objective-C. Everything that may run on the audio I/O thread.
//   ZTronDSPCore       Units, domains, environment, pipeline DSL, plan compiler, engine, feeds,
//                      mock sources, toolkit. No processing stage (EXT-1).
//   ZTronDSPDesign     LTI design and analysis; the sequence stages.
//   ZTronDSPMetal      Textures, renderers, GPU kernels. No views.
//   ZTronDSPAnalysis   Spectral steps and recipes, their strategies, the analyses.
//   ZTronDSPIO         Hardware input, node tap, file source, audio-session policy.
//   ZTronDSPUI         Views, modifiers, gestures, pipeline hosts.
//   ZTronDSP           The facade: re-exports Core, Design, Analysis, IO and Metal.
//   ZTronDSPTesting    What the author of a stage needs to test it. Its C half is the target
//                      CZTronDSPTesting, because one SwiftPM target holds one language.
//
// The package is built and tested with `xcodebuild` against an iOS destination (DEP-4).
// Tools version 6.2 is what lets the manifest turn clang's function-effect warnings into
// errors for the C target without unsafe flags (E-32).

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "ZTronDSP",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ZTronDSP", targets: ["ZTronDSP"]),
        .library(name: "ZTronDSPUI", targets: ["ZTronDSPUI"]),
        .library(name: "ZTronDSPTesting", targets: ["ZTronDSPTesting"]),
    ],
    targets: [
        // MARK: Production targets

        .target(
            name: "CZTronDSP",
            cSettings: [
                // RT-1, RT-7(1): a `nonblocking` function that allocates, or calls a function
                // that is not itself `nonblocking`, does not build.
                .enableWarning("function-effects"),
                .treatWarning("function-effects", as: .error),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFAudio"),
            ]
        ),
        .target(
            name: "ZTronDSPCore",
            dependencies: ["CZTronDSP"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ZTronDSPDesign",
            dependencies: ["ZTronDSPCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ZTronDSPMetal",
            dependencies: ["ZTronDSPCore"],
            // The build compiles Shaders/*.metal into default.metallib in the target's resource
            // bundle, which MetalContext loads (DEP-4): building needs Xcode's Metal Toolchain
            // component (`xcodebuild -downloadComponent MetalToolchain`).
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ZTronDSPAnalysis",
            dependencies: ["ZTronDSPCore", "ZTronDSPDesign", "ZTronDSPMetal"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ZTronDSPIO",
            dependencies: ["ZTronDSPCore", "CZTronDSP"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ZTronDSPUI",
            dependencies: ["ZTronDSPCore", "ZTronDSPAnalysis", "ZTronDSPMetal"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ZTronDSP",
            dependencies: ["ZTronDSPCore", "ZTronDSPDesign", "ZTronDSPAnalysis", "ZTronDSPIO", "ZTronDSPMetal"],
            swiftSettings: swiftSettings
        ),

        // MARK: Test product

        .target(name: "CZTronDSPTesting"),
        .target(
            name: "ZTronDSPTesting",
            dependencies: ["ZTronDSPCore", "CZTronDSPTesting"],
            swiftSettings: swiftSettings
        ),

        // MARK: Test targets, one per target

        .testTarget(
            name: "CZTronDSPTests",
            dependencies: ["CZTronDSP", "ZTronDSPTesting"],
            // Golden vectors travel inside the test bundle, so the parity plans also run on a device.
            resources: [.copy("Golden")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronDSPCoreTests",
            dependencies: ["ZTronDSPCore", "ZTronDSPTesting"],
            // Golden vectors travel inside the test bundle, so the parity plans also run on a device.
            resources: [.copy("Golden")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronDSPDesignTests",
            dependencies: ["ZTronDSPDesign", "ZTronDSPTesting"],
            // Golden vectors travel inside the test bundle, so the parity plans also run on a device.
            resources: [.copy("Golden")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronDSPMetalTests",
            dependencies: ["ZTronDSPMetal", "ZTronDSPTesting"],
            // Golden images travel inside the test bundle (§8.5).
            resources: [.copy("Golden")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronDSPAnalysisTests",
            dependencies: ["ZTronDSPAnalysis", "ZTronDSPTesting"],
            // Golden vectors travel inside the test bundle, so the parity plans also run on a device.
            resources: [.copy("Golden")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronDSPIOTests",
            dependencies: ["ZTronDSPIO", "ZTronDSPTesting"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronDSPUITests",
            dependencies: ["ZTronDSPUI", "ZTronDSPTesting", "ZTronDSPIO", "ZTronDSPDesign"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronDSPTests",
            dependencies: ["ZTronDSP", "ZTronDSPTesting"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZTronDSPTestingTests",
            dependencies: ["ZTronDSPTesting"],
            swiftSettings: swiftSettings
        ),
    ],
    cLanguageStandard: .c11
)
