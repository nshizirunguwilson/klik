// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Klik",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Klik",
            path: "Sources/Klik"
        )
    ]
)
