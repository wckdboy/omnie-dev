// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OmnieKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DesignKit", targets: ["DesignKit"]),
        .library(name: "CommandKit", targets: ["CommandKit"]),
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit"]),
        .library(name: "GitKit", targets: ["GitKit"]),
    ],
    targets: [
        .target(name: "DesignKit"),
        .target(name: "CommandKit"),
        .target(name: "WorkspaceKit"),
        // Built by scripts/build-libgit2.sh.
        .binaryTarget(name: "Clibgit2", path: "Vendor/Clibgit2.xcframework"),
        .target(name: "GitKit", dependencies: ["Clibgit2"]),
        .testTarget(name: "DesignKitTests", dependencies: ["DesignKit"]),
        .testTarget(name: "CommandKitTests", dependencies: ["CommandKit"]),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
    ]
)
