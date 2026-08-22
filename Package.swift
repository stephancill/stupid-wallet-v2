// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StupidWallet",
    platforms: [
        .iOS(.v17)
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
            name: "StupidWalletCore"
        ),
        .target(
            name: "StupidWallet",
            dependencies: ["StupidWalletCore"]
        ),
        .target(
            name: "StupidWalletSafari",
            dependencies: ["StupidWalletCore"]
        ),
    ]
)