// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppVisitors",
    // macOS is included only so `swift test` runs on the host; the SDK targets iOS apps.
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "AppVisitors", targets: ["AppVisitors"]),
    ],
    targets: [
        .target(
            name: "AppVisitors",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AppVisitorsTests",
            dependencies: ["AppVisitors"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
