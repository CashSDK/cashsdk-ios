// swift-tools-version: 5.9
//
// CashSDK — native iOS SDK for in-app purchases, entitlements, and paywalls.
// StoreKit 2 + async/await, zero third-party dependencies.
//
import PackageDescription

let package = Package(
    name: "CashSDK",
    platforms: [
        // StoreKit 2 (`Product`, `Transaction.updates`, `AppStore.sync`) requires iOS 15+.
        .iOS(.v15),
        // macOS is a secondary build target so the package compiles + tests on a Mac host
        // (and CI) without an iOS simulator. StoreKit 2 lands on macOS 13 and the SwiftUI
        // paywall uses a couple of macOS-14 shape APIs; UIKit-only code is already behind
        // `#if canImport(UIKit)`, so it drops out cleanly off-iOS.
        .macOS(.v14)
    ],
    products: [
        .library(name: "CashSDK", targets: ["CashSDK"])
    ],
    targets: [
        .target(
            name: "CashSDK",
            path: "Sources/CashSDK"
        ),
        // Runs on the macOS host (`swift test`) — no simulator required. Covers the pure,
        // host-independent seams: token derivation, the owner-keyed entitlement cache, the
        // verify-attribution heuristic, and identity-mutation ordering.
        .testTarget(
            name: "CashSDKTests",
            dependencies: ["CashSDK"],
            path: "Tests/CashSDKTests"
        )
    ]
)
