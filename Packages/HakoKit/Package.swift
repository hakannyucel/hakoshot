// swift-tools-version: 6.2
// HakoKit: pure logic for HakoShot. No AppKit / SwiftUI imports allowed
// (CoreGraphics, ImageIO, CoreImage, CoreText, Vision are fine). See plan §3.1.

import PackageDescription

let package = Package(
    name: "HakoKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "HakoKit", targets: ["HakoKit"]),
    ],
    dependencies: [
        // ImageIO can decode WebP but this OS's ImageIO can't *write* it
        // (spiked in WP7.3: `CGImageDestinationCopyTypeIdentifiers()` omits
        // `org.webmproject.webp`). This is Google's libwebp C sources,
        // vendored for SPM by the SDWebImage project (also used by
        // SDWebImageWebPCoder) — not a Swift wrapper, so HakoKit calls the C
        // API directly from `Export/WebPEncoder.swift`.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "HakoKit",
            dependencies: [
                .product(name: "libwebp", package: "libwebp-Xcode"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "HakoKitTests",
            dependencies: ["HakoKit"],
            exclude: ["Fixtures"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
