// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ONESurfaceSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ONESurfaceSpike",
            resources: [.process("Resources")]
        )
    ]
)
