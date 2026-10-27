// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WoodShop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WoodShop", path: "Sources/WoodShop"),
        .testTarget(name: "WoodShopTests", dependencies: ["WoodShop"])
    ]
)
