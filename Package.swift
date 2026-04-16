// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "FSRS",
    products: [
        .library(name: "FSRS", targets: ["FSRS"]),
    ],
    targets: [
        .target(name: "FSRS"),
        .testTarget(name: "FSRSTests", dependencies: ["FSRS"]),
    ],
    swiftLanguageModes: [.v6]
)
