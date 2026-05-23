// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AINotebook",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AINotebookCore",
            targets: ["AINotebookCore"]
        ),
        .executable(
            name: "AINotebookApp",
            targets: ["AINotebookApp"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AINotebookCore"
        ),
        .executableTarget(
            name: "AINotebookApp",
            dependencies: ["AINotebookCore"]
        ),
        .testTarget(
            name: "AINotebookCoreTests",
            dependencies: ["AINotebookCore"]
        )
    ]
)
