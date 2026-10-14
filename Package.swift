// swift-tools-version: 5.9
//
// CashSDK: native iOS SDK for in-app purchases, entitlements, and paywalls.
// StoreKit 2 + async/await, zero third-party dependencies.
//
import PackageDescription

let package = Package(
    name: "CashSDK",
    platforms: [
        // StoreKit 2 (`Product`, `Transaction.updates`, `AppStore.sync`) requires iOS 15+.
        .iOS(.v15),
        // macOS 12 is what CashSDKCommerce (direct Mac apps with Stripe) needs. The StoreKit
        // `CashSDK` target compiles there too: StoreKit 2 is macOS 12+, and its newer APIs
        // (`Transaction.environment`, `Transaction.reason`, promoted purchases) sit behind
        // `#available` checks. Its documented support for a Mac App Store app stays macOS 14+.
        // UIKit-only code is behind `#if canImport(UIKit)`, so it drops out cleanly off-iOS.
        .macOS(.v12)
    ],
    products: [
        .library(name: "CashSDK", targets: ["CashSDK"]),
        .library(name: "CashSDKCommerce", targets: ["CashSDKCommerce"])
    ],
    targets: [
        .target(name: "CashSDKCommerce", path: "Sources/CashSDKCommerce"),
        .testTarget(name: "CashSDKCommerceTests", dependencies: ["CashSDKCommerce"], path: "Tests/CashSDKCommerceTests"),
        .target(
            name: "CashSDK",
            path: "Sources/CashSDK"
        ),
        // Runs on the macOS host (`swift test`), with no simulator required. Covers the pure,
        // host-independent seams: token derivation, the owner-keyed entitlement cache, the
        // verify-attribution heuristic, and identity-mutation ordering.
        .testTarget(
            name: "CashSDKTests",
            dependencies: ["CashSDK"],
            path: "Tests/CashSDKTests"
        )
    ]
)
