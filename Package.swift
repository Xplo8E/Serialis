// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Serialis",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Serialis", targets: ["Serialis"])],
    targets: [
        .target(name: "SerialisCore"),
        // Xcode compiles the app icon into the application bundle.
        .executableTarget(name: "Serialis", dependencies: ["SerialisCore"], exclude: ["Assets.xcassets"]),
        .testTarget(name: "SerialisCoreTests", dependencies: ["SerialisCore"])
    ]
)
