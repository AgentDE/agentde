// swift-tools-version:5.9
// Vendored SwiftTerm 1.20.0 (MIT). Trimmed manifest for Den: Shaders.metal ships as a
// plain resource so it compiles at runtime, which avoids needing Xcode's `metal` tool.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            resources: [.copy("Apple/Metal/Shaders.metal")]
        ),
    ]
)
