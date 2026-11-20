// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TablePeek",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TablePeek", targets: ["TablePeek"]),
        .executable(name: "tablepeek-cli", targets: ["tablepeek-cli"]),
    ],
    targets: [
        .target(name: "TablePeekCore"),
        .executableTarget(name: "TablePeek", dependencies: ["TablePeekCore"]),
        .executableTarget(name: "tablepeek-cli", dependencies: ["TablePeekCore"]),
    ]
)
