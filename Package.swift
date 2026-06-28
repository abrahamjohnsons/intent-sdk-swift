// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Intent",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "Intent", targets: ["Intent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.4.0"),
    ],
    targets: [
        .target(
            name: "Intent",
            dependencies: [
                .product(name: "Lottie", package: "lottie-spm"),
            ],
            path: "Sources/Intent"
        ),
    ]
)
