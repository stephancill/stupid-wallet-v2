// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StupidWallet",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // A stupid-app project contains one library product per app/extension bundle.
        .library(
            name: "StupidWallet",
            targets: ["StupidWallet"],
        ),
        .library(
            name: "StupidWalletSafari",
            targets: ["StupidWalletSafari"],
        ),
    ],
    targets: [
        .target(
            name: "CSecp256k1",
            path: "Sources/CSecp256k1",
            publicHeadersPath: "include",
            cSettings: [
                .define("ENABLE_MODULE_RECOVERY"),
                .define("ENABLE_MODULE_ECDH"),
            ]
        ),
        .target(
            name: "StupidWalletCore",
            dependencies: ["CSecp256k1"]
        ),
        .target(
            name: "StupidWallet",
            dependencies: ["StupidWalletCore"]
        ),
        .target(
            name: "StupidWalletSafari",
            dependencies: ["StupidWalletCore"]
        ),
        .testTarget(
            name: "StupidWalletCoreTests",
            dependencies: ["StupidWalletCore"]
        ),
    ]
)