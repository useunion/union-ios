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
        // The crash handler's signal/mach path is C because it has to be: a handler runs on a dying
        // thread that may hold the malloc lock, and Swift cannot promise async-signal-safety — even a
        // retain is a runtime call. See Sources/UnionCrashCore/include/union_crash.h.
        .target(name: "UnionCrashCore"),
        .target(
            name: "Union",
            dependencies: ["UnionCrashCore"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "UnionTests",
            dependencies: ["Union", "UnionCrashCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
