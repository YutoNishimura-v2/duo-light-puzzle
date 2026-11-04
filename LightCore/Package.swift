// swift-tools-version: 6.0
import PackageDescription

// 光の反射の計算とステージの型。画面に依存しないので Linux でもテストできる
let package = Package(
    name: "LightCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LightCore", targets: ["LightCore"])],
    targets: [
        .target(name: "LightCore"),
        .testTarget(name: "LightCoreTests", dependencies: ["LightCore"]),
    ]
)
