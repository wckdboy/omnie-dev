// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OmnieKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DesignKit", targets: ["DesignKit"]),
        .library(name: "CommandKit", targets: ["CommandKit"]),
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit"]),
    ],
    targets: [
        .target(name: "DesignKit"),
        .target(name: "CommandKit"),
        .target(name: "WorkspaceKit"),
        .testTarget(name: "DesignKitTests", dependencies: ["DesignKit"]),
        .testTarget(name: "CommandKitTests", dependencies: ["CommandKit"]),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit"]),
    ]
)
