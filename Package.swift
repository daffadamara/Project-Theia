// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Theia",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "theia-cli", targets: ["theia-cli"]),
        .executable(name: "theia-viewer", targets: ["theia-viewer"]),
        .executable(name: "theia-tests", targets: ["theia-tests"]),
        .library(name: "TheiaCore", targets: ["TheiaCore"]),
    ],
    targets: [
        // Portable C++ core engine. Encapsulates metal-cpp; exposes a clean,
        // Swift-safe API via the public headers in include/Theia.
        .target(
            name: "TheiaCore",
            path: "Sources/TheiaCore",
            publicHeadersPath: "include",
            cxxSettings: [
                // Allow quote-includes of root-level headers (e.g. "GPUContext.hpp")
                // and subdir headers ("nodes/...", "kernels/...") from any source.
                .headerSearchPath("."),
                // Vendored single-header libs: #include "stb_image_write.h".
                .headerSearchPath("third_party"),
                // metal-cpp is included as <Metal/Metal.hpp>, <Foundation/...>, etc.
                .headerSearchPath("third_party/metal-cpp"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        // Thin Swift "shell": the CLI. Calls into TheiaCore through C++ interop.
        .executableTarget(
            name: "theia-cli",
            dependencies: ["TheiaCore"],
            path: "Sources/theia-cli",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        // Interactive 3D viewport. Windowed AppKit + MetalKit app (built via
        // SwiftPM, no Xcode); also supports an offscreen --shot render mode.
        .executableTarget(
            name: "theia-viewer",
            dependencies: ["TheiaCore"],
            path: "Sources/theia-viewer",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        // Self-contained test runner. `swift test` (XCTest) is unavailable in a
        // Command-Line-Tools-only environment, so tests are an executable that
        // exits non-zero on failure: `swift run theia-tests`.
        .executableTarget(
            name: "theia-tests",
            dependencies: ["TheiaCore"],
            path: "Tests/theia-tests",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
