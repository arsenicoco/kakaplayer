// swift-tools-version: 5.9
// Prebuilt VLCKit 4.0 (LGPL 2.1), macOS slice of VLCKit-4.0-20260831-1526.zip,
// see scripts/fetch-vlckit.sh. Embedded as a dynamic framework.
import PackageDescription

let package = Package(
    name: "VLCKitBinary",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VLCKit", targets: ["VLCKit"])
    ],
    targets: [
        .binaryTarget(name: "VLCKit", path: "VLCKit.xcframework")
    ]
)
