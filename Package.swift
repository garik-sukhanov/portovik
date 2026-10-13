// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portovik",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Portovik",
            path: "Sources/Portovik",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PortovikTests",
            dependencies: ["Portovik"],
            path: "Tests/PortovikTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
