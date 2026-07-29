// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Mu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MuCore", targets: ["MuCore"]),
        .executable(name: "MuApp", targets: ["MuApp"])
    ],
    targets: [
        .target(
            name: "MuCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MuApp",
            dependencies: ["MuCore"]
        ),
        .testTarget(
            name: "MuCoreTests",
            dependencies: ["MuCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
