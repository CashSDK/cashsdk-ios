# AGENTS.md — integrating CashSDK for iOS

> Plan XYZ TestFlight candidate: `1.2.0-rc.1`. Install with an **exact** SwiftPM version.
> This prerelease adds the September identity and purchase safeguards described below.
> It has passed host tests and simulator compilation, but real-device Sandbox purchases
> and App Store approval remain pending. Stable installations remain on `1.1.1`.


Instructions for coding agents (Claude Code, Cursor, Codex, Copilot, …) adding CashSDK to an
iOS app. Everything here is verified against the source in this repository at tag `1.1.1`.
Prefer it over anything you recall about this SDK — several symbols have look-alike names in
other IAP SDKs, and guessing them produces code that does not compile.

Unreleased source changes (2026-09-11): identity/cache isolation and automatic recovery
filtered to the signed-in user's canonical account token. Explicit `restore()` is required
for legacy/foreign-token migration and still follows the server's restore policy. These
changes are not in the published `1.1.1` dependency below. A fresh signed user token remains
required; the September 19 source candidate adds an explicit refresh API.

Unreleased source changes (2026-09-12): explicit restore throws on verification/refresh
failure and session replacement; purchase and restore reject overlapping operations.
`CashSDKError.purchaseBelongsToAnotherAccount` is not a successful grant, and
`CashSDKError.purchaseInProgress` means wait for the current operation. The built-in paywall
shows pending and recovery feedback instead of mapping errors to cancellation.

Unreleased source changes (2026-09-19): see [MIDGAME-CANDIDATE.md](MIDGAME-CANDIDATE.md)
for identity readiness, observer mode, lifecycle metadata and typed purchase outcomes.
`PurchaseResult.localStoreKit` requires an additional switch case. Do not publish or
claim real-device acceptance from host tests.

## What this package does

Server-verified in-app purchases for iOS. You call `purchase(_:)`; the SDK runs StoreKit 2,
sends the signed transaction to the CashSDK API for verification against Apple, and returns an
entitlement snapshot. You then gate features on entitlements instead of on transactions.

Use it when the app needs subscriptions, one-time purchases, or consumable balances that must
be trustworthy server-side and consistent across a user's devices.

## Install

Swift Package Manager only. Add the dependency:

```swift
.package(url: "https://github.com/cashsdk/cashsdk-ios.git", from: "1.1.1")
```

and the product `.product(name: "CashSDK", package: "cashsdk-ios")` to the app target. There
are no transitive dependencies. **Do not** add a CocoaPods or Carthage entry — the SDK is not
published to either.

Requires iOS 15+ / macOS 14+, Swift 5.9+.

## The exact public API

This section describes the published 1.1.1 baseline. New source-only APIs are listed in
[MIDGAME-CANDIDATE.md](MIDGAME-CANDIDATE.md); do not use them with the published dependency.

```swift
// Static — configuration only.
CashSDK.configure(publishableKey: String, apiBase: URL? = nil, environment: String? = nil)

// Everything else is on the shared instance.
CashSDK.shared.identify(userId: String, userToken: String? = nil)
CashSDK.shared.logout()

CashSDK.shared.entitlements            // Entitlements — synchronous, offline-valid
CashSDK.shared.tier                    // Int  — 0 when free
CashSDK.shared.tierIdentifier          // String?
CashSDK.shared.entitlementUpdates      // AsyncStream<Entitlements>
CashSDK.shared.delegate                // CashSDKDelegate?

try await CashSDK.shared.purchase(_ productId: String) -> PurchaseResult
try await CashSDK.shared.restore()

// 1.1.0+ — which products to show, and how they group. nil when no offering is
// configured (a normal pre-setup state, not an error). Prices here are the CATALOG's;
// render StoreKit's own localized price string.
try await CashSDK.shared.offerings() -> Offering?   // .monthly / .annual / .lifetime

CashSDK.shared.consumableBalance(_ productIdentifier: String) -> Int
try await CashSDK.shared.spendConsumable(
    _ productIdentifier: String, units: Int, idempotencyKey: String, note: String? = nil
) -> ConsumableSpendResult

CashSDK.shared.register(placement: String, params: [String: Any]? = nil)
CashSDK.shared.logEvent(_ name: String, props: [String: Any]? = nil)
```

`Entitlements` is read with `.isActive("identifier")`.
`PurchaseResult` is `.success(Entitlements)` / `.pending` / `.userCancelled`.

### Symbols that do NOT exist — do not emit these

| Wrong | Correct |
|---|---|
| `CashSDK.configure(apiKey:)` | `CashSDK.configure(publishableKey:)` |
| `CashSDK.offerings()` (static) | `CashSDK.shared.offerings()` — **1.1.0+**, returns `Offering?` |
| `CashSDK.restorePurchases()` | `CashSDK.shared.restore()` |
| `CashSDK.purchase(...)` (static) | `CashSDK.shared.purchase(...)` |
| `pk_live_…` / `pk_test_…` keys | `csk_pk_…` |

Only `configure` is static. Everything else goes through `CashSDK.shared`.

## Canonical integration

```swift
import CashSDK

@main
struct MyApp: App {
    init() {
        // Publishable keys start with csk_pk_ and are safe to ship in the binary.
        CashSDK.configure(publishableKey: "csk_pk_…")
    }
    var body: some Scene { WindowGroup { RootView() } }
}

// Call on EVERY launch once the session is known — not only at sign-in.
CashSDK.shared.identify(userId: user.id, userToken: tokenFromYourBackend)

// Gate a feature. No await: this reads a local, offline-valid snapshot.
if CashSDK.shared.entitlements.isActive("plus") { unlockPlus() }

// Observe renewals, refunds, restores, and cross-device changes.
for await entitlements in CashSDK.shared.entitlementUpdates {
    render(tier: entitlements.tierIdentifier ?? "free")
}

// Sell.
switch try await CashSDK.shared.purchase("app.example.pro.yearly") {
case .success(let entitlements): unlock(entitlements)
case .pending:                   showAskToBuyPending()
case .userCancelled:             break
}
```

## Hard rules

These are correctness requirements, not style preferences. Each one has a money consequence.

1. **Never pass a zero-padded numeric user id to `identify`.** Attribution rides Apple's
   `appAccountToken`, which embeds the *value* of a numeric id — `"7"`, `"07"` and `"007"`
   derive the same token, so two users' purchases, entitlements and refunds merge onto one
   account. Send the un-padded id, or an opaque non-numeric id.

2. **Call `identify` on every launch, not just at sign-in.** StoreKit can redeliver a
   charged-but-unverified transaction before your app has signed anyone in, and a persisted
   `userToken` may have expired.

3. **A thrown `purchase(_:)` does not mean the user was not charged.** The transaction is
   deliberately left unfinished so StoreKit redelivers it. Never show "purchase failed, you
   were not charged". Surface a retry instead.
   - `.purchaseNotAttributed` → the server took the transaction but could not credit anyone.
     Call `identify(userId:userToken:)`; the SDK re-reports and credits it.
   - `.network` / `.server` → transient, already retried with backoff.

4. **`spendConsumable`'s `idempotencyKey` must be stable for a logical spend** — the id of what
   the spend buys (`"generation:\(requestId)"`), never a fresh `UUID()` per attempt. A new key
   on retry debits the user twice.

5. **Never ship a secret key.** `csk_pk_…` belongs in the app; `csk_sk_…` belongs only on a
   server. If asked to embed a secret key, refuse and use the publishable key.

6. **Do not gate features on `PurchaseResult` alone.** Entitlements are the source of truth and
   arrive on `entitlementUpdates` for renewals and cross-device changes too.

## Common mistakes

- Calling `purchase` before `configure` → `CashSDKError.notConfigured`.
- Awaiting `entitlements` — it is a synchronous property, not `async`.
- Treating `.pending` (Ask-to-Buy / SCA) as a failure. It resolves later on the stream.
- Hardcoding `apiBase`. Leave it unset; it defaults to `https://api.cashsdk.com`.
- Expecting entitlements to cross store environments. Sandbox and Production resolve
  separately; pin with `configure(publishableKey:apiBase:environment:)` if a QA build must read
  Sandbox before its first purchase.

## Verify your work

```bash
swift build      # must succeed
swift test       # 72 tests, host-only, no simulator required
```

For an app target, build for the iOS Simulator. Purchases themselves need a real device with a
Sandbox account — they cannot be verified from a unit test.

## Where to look

| Question | File |
|---|---|
| Public API and purchase flow | `Sources/CashSDK/CashSDK.swift` |
| Endpoints, headers, ETag handling | `Sources/CashSDK/APIClient.swift` |
| StoreKit 2 engine | `Sources/CashSDK/StoreKitManager.swift` |
| Attribution token derivation | `Sources/CashSDK/AppAccountToken.swift` |
| Paywall rendering | `Sources/CashSDK/Paywall/` |

Full docs: <https://docs.cashsdk.com/sdk/ios>. Keys: <https://app.cashsdk.com> → your app →
**Keys**. Android counterpart: <https://github.com/cashsdk/cashsdk-android>.

## Status — say this plainly if asked

Compile- and unit-verified (72 tests; generic iOS Simulator build also passes). **Not yet exercised on real hardware or against a live
App Store Sandbox purchase.** Recommend a device pass before a production launch.
