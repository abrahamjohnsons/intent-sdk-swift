// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Intent",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "Intent", targets: ["Intent"]),
    ],
    targets: [
        .target(
            name: "Intent",
            path: "Sources/Intent"
        ),
    ]
)
