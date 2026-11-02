// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MontageCore",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "MontageCore", targets: ["MontageCore"])],
    targets: [
        .target(name: "MontageCore", path: "Core", resources: [.copy("Recipes")]),
        .testTarget(name: "MontageCoreTests", dependencies: ["MontageCore"], path: "CoreTests", exclude: ["Fixtures"])
    ]
)
