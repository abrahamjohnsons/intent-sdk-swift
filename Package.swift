// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ACO",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "ACO", targets: ["ACO"]),
    ],
    targets: [
        .target(
            name: "ACO",
            path: "Sources/ACO"
        ),
    ]
)
