// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Union",
    // macOS is included only so `swift test` runs on the host; the SDK targets iOS apps.
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "Union", targets: ["Union"]),
    ],
    targets: [
        .target(
            name: "Union",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "UnionTests",
            dependencies: ["Union"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
