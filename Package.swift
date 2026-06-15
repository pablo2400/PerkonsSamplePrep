// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PerkonsSamplePrep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PerkonsSamplePrep", targets: ["PerkonsSamplePrep"])
    ],
    targets: [
        .executableTarget(name: "PerkonsSamplePrep")
    ]
)
