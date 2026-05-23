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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "AINotebookCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
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
