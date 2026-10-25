// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Uso",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Uso",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(name: "UsoTests", dependencies: ["Uso"]),
    ]
)
