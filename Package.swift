// swift-tools-version: 6.2
// Vega with Apple's server packages: VegaNIO runs SwiftNIO's EventLoopGroup,
// Channel and bootstraps on Vega; VegaSwiftMetrics and VegaLogging report
// Vega's runtime metrics and slow polls through swift-metrics and swift-log.
// A package of its own, so that Vega itself keeps no dependencies.
import PackageDescription

/// Vega, by version; or, with VEGA_PATH set, a local checkout -- for working
/// on both before a Vega release has what this package needs.
let vega: Package.Dependency = Context.environment["VEGA_PATH"].map {
    .package(path: $0)
} ?? .package(url: "https://github.com/grepjava/vega.git", from: "1.1.0")

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "VegaNIO",
    platforms: [.macOS("26.4"), .iOS("26.4")],
    products: [
        .library(name: "VegaNIO", targets: ["VegaNIO"]),
        .library(name: "VegaSwiftMetrics", targets: ["VegaSwiftMetrics"]),
        .library(name: "VegaLogging", targets: ["VegaLogging"]),
    ],
    dependencies: [
        vega,
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.86.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0"),
    ],
    targets: [
        // SwiftNIO's EventLoopGroup, Channel and bootstraps over Vega.
        .target(
            name: "VegaNIO",
            dependencies: [
                .product(name: "Vega", package: "vega"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        // Runtime.metrics, sampled and recorded through swift-metrics.
        .target(
            name: "VegaSwiftMetrics",
            dependencies: [
                .product(name: "Vega", package: "vega"),
                .product(name: "VegaMetrics", package: "vega"),
                .product(name: "Metrics", package: "swift-metrics"),
            ],
            swiftSettings: swiftSettings
        ),
        // Runtime.onSlowPoll, logged through swift-log.
        .target(
            name: "VegaLogging",
            dependencies: [
                .product(name: "Vega", package: "vega"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "VegaNIOTests",
            dependencies: [
                "VegaNIO",
                .product(name: "Vega", package: "vega"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "VegaAdaptersTests",
            dependencies: [
                "VegaSwiftMetrics", "VegaLogging",
                .product(name: "Vega", package: "vega"),
                .product(name: "MetricsTestKit", package: "swift-metrics"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
