// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Serialis",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Serialis", targets: ["Serialis"])],
    targets: [
        .target(name: "SerialisCore"),
        .executableTarget(name: "Serialis", dependencies: ["SerialisCore"]),
        .testTarget(name: "SerialisCoreTests", dependencies: ["SerialisCore"])
    ]
)
