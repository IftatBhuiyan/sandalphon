// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sandalphon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypeEngine", targets: ["TypeEngine"]),
        .executable(name: "Sandalphon", targets: ["Sandalphon"]),
        .executable(name: "sandalphon-eval", targets: ["sandalphon-eval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // The correction engine: no AppKit, no I/O beyond loading its data files.
        .target(name: "TypeEngine", swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        // The menu-bar app: keyboard tap, Accessibility, settings window.
        .executableTarget(
            name: "Sandalphon",
            dependencies: ["TypeEngine", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Command-line quality checks used by scripts/benchmark.sh.
        .executableTarget(name: "sandalphon-eval", dependencies: ["TypeEngine"]),
        // The engine as WebAssembly for the website demo (scripts/build-web.sh).
        .executableTarget(name: "sandalphon-web", dependencies: ["TypeEngine"]),
        .testTarget(name: "TypeEngineTests", dependencies: ["TypeEngine"]),
    ]
)
