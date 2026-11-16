// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blinky",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "Blinky", path: "Sources/Blinky")
    ]
)
