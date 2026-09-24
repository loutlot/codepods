// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Codepods",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Codepods")]
)
