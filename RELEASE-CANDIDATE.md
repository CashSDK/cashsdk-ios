# CashSDK iOS 1.2.0-rc.1

Immutable prerelease for the Plan XYZ TestFlight integration. Stable `1.1.1` is unchanged.

```swift
.package(url: "https://github.com/cashsdk/cashsdk-ios.git", exact: "1.2.0-rc.1")
```

Runtime source is the September 19 integration candidate: awaitable identity, frozen
transaction ownership, typed purchase/restore failures, deadline-aware entitlements,
and server-confirmed purchase outcomes. Switches must handle `.localStoreKit`, which
never grants server access. See `MIDGAME-CANDIDATE.md` for the API contract.

The matching CashSDK API contract is deployed before Plan XYZ checkout. Verification
includes 72 host tests, a generic iOS Simulator build, API unit/HTTP integration tests,
and a production Docker build. Those checks do not establish real-device purchase,
renewal, refund or restore acceptance. Complete Sandbox device acceptance before
promoting this candidate to a stable release. No existing tag may be rewritten.
