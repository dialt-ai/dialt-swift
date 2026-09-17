// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dialt-swift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Dialt", targets: ["Dialt"]),
        .executable(name: "dialt-diagnostics", targets: ["DialtDiagnostics"]),
        .executable(name: "DialtMacVoice", targets: ["DialtMacVoice"])
    ],
    targets: [
        .target(name: "Dialt"),
        .executableTarget(name: "DialtDiagnostics", dependencies: ["Dialt"]),
        .executableTarget(name: "DialtMacVoice", dependencies: ["Dialt"], path: "Examples/MacVoice"),
        .testTarget(name: "DialtTests", dependencies: ["Dialt"])
    ],
    swiftLanguageModes: [.v6]
)
