// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDiskLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDiskLens", targets: ["MacDiskLens"])
    ],
    targets: [
        .executableTarget(name: "MacDiskLens")
    ]
)
