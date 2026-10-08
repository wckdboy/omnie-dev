// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "GitKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "GitKit", targets: ["GitKit"])],
    targets: [
        // libgit2 + libssh2 + libcrypto, built by scripts/build-git-deps.sh. Moves to a
        // binaryTarget(url:checksum:) from omnie-dev-native-deps releases (PLAN §27.3).
        .binaryTarget(name: "Clibgit2", path: "Vendor/Clibgit2.xcframework"),
        .target(name: "CGitSSH", dependencies: ["Clibgit2"]),
        .target(name: "GitKit", dependencies: ["Clibgit2", "CGitSSH"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
    ]
)
