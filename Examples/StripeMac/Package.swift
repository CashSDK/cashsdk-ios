// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "StripeMac", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "cashsdk-ios", path: "../..")],
    targets: [.executableTarget(name: "StripeMac", dependencies: [.product(name: "CashSDKCommerce", package: "cashsdk-ios")])]
)
