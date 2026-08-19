// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TottaCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TottaCore", targets: ["TottaCore"]),
    ],
    targets: [
        .target(name: "TottaCore"),
        .testTarget(name: "TottaCoreTests", dependencies: ["TottaCore"]),
    ]
)
