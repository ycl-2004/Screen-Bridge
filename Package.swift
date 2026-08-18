// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Screen Bridge",
    platforms: [
        .macOS(.v14), // Target modern macOS for ScreenCaptureKit
        .iOS(.v13)    // Target iOS 13+ for Receiver
    ],
    products: [
        .executable(name: "BetterCastSender", targets: ["BetterCastSender"]),
        .executable(name: "BetterCastReceiverIOS", targets: ["BetterCastReceiverIOS"]),
        .library(name: "BetterCastShared", targets: ["BetterCastShared"]),
    ],
    targets: [
        .target(
            name: "BetterCastShared",
            linkerSettings: [
                .linkedFramework("CryptoKit"),
                .linkedFramework("Security")
            ]
        ),
        // Static library for Objective-C VirtualDisplay code
        .target(
            name: "VirtualDisplayLib",
            path: "Sources/BetterCastSender/VirtualDisplay",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath(".")
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface")
            ]
        ),
        .executableTarget(
            name: "BetterCastSender",
            dependencies: ["VirtualDisplayLib", "BetterCastShared"],
            exclude: ["VirtualDisplay"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Network"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "BetterCastReceiverIOS",
            dependencies: ["BetterCastShared"],
            path: "Sources/BetterCastReceiverIOS",
            exclude: ["Assets.xcassets", "Info.plist", "LaunchScreen.storyboard"],
            linkerSettings: [
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
                .linkedFramework("Network"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "BetterCastSharedTests",
            dependencies: ["BetterCastShared"]
        ),
    ]
)
