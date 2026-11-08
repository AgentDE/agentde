// swift-tools-version:5.10
import PackageDescription

// AgentDE: the app's core (as a library), the extension API every extension builds against, and the terminal
// holder. The app itself is assembled with its extensions by scripts/build-app.sh (see extensions.json).
let package = Package(
    name: "agentde",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDEKit", targets: ["AgentDEKit"]),
        .library(name: "AgentDE", targets: ["AgentDE"]),
        .executable(name: "agentde-pty", targets: ["agentde-pty"]),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        // The extension API, plus the shared theme, views and helpers extensions use.
        .target(name: "AgentDEKit", path: "Sources/AgentDEKit"),
        .target(name: "AgentDE", dependencies: ["SwiftTerm", "AgentDEKit"], path: "Sources/AgentDE"),
        // Holds a tab's terminal so it survives the app quitting, updating or crashing (see docs/ARCHITECTURE.md).
        .executableTarget(name: "agentde-pty", path: "Sources/agentde-pty"),
        .testTarget(name: "AgentDETests", dependencies: ["AgentDE", "agentde-pty", "SwiftTerm"], path: "Tests/AgentDETests"),
    ]
)
