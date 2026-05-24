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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(
            name: "AINotebookCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SwiftSoup",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .executableTarget(
            name: "AINotebookApp",
            dependencies: ["AINotebookCore"],
            resources: [
                .copy("Resources/editor")
            ]
        ),
        .testTarget(
            name: "AINotebookCoreTests",
            dependencies: ["AINotebookCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
