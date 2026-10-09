// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "FinderSearch", platforms: [.macOS("15.0")],
    products: [.executable(name: "FinderSearch", targets: ["FinderSearch"])],
    targets: [
        .executableTarget(name: "FinderSearch"),
        .testTarget(name: "FinderSearchTests", dependencies: ["FinderSearch"]),
    ])
