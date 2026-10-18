// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Rustle",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Rustle", targets: ["Rustle"])],
    targets: [
        .executableTarget(name: "Rustle"),
        .testTarget(name: "RustleTests", dependencies: ["Rustle"])
    ],
    swiftLanguageVersions: [.v5]
)
