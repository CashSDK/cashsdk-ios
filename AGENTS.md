# AGENTS.md: CashSDK for iOS

Instructions for coding agents adding CashSDK to an iOS or macOS app, or maintaining this SDK.

**Published version: 2.3.0** (Swift Package Manager, git tag `2.2.0`). Everything below matches
the source at that tag. Trust it over what you remember about this SDK: other IAP SDKs use
look-alike names, and guessed names do not compile.

This repository is published from the CashSDK source tree. Edits made directly here are
overwritten by the next release, so send changes as a pull request or an issue instead.

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/cashsdk/cashsdk-ios.git", from: "2.3.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "CashSDK", package: "cashsdk-ios")
    ])
]
```

In Xcode: File → Add Package Dependencies, paste `https://github.com/cashsdk/cashsdk-ios`, and add
`CashSDK` to the app target. No transitive dependencies. There is no CocoaPods or Carthage
release, so do not add either. Requires iOS 15+ or macOS 14+, Swift 5.9+.

**macOS (2.3.0+).** The same package, API and publishable key work in a native macOS app and in
Mac Catalyst. `register(placement:)` presents the dashboard paywall on the Mac too (a sheet on
the key window, or its own window); do not build a substitute paywall unless the merchant sells
from their own screen. Add the In-App Purchase capability to the macOS target. If the Mac app has
its OWN App Store Connect record (its own bundle id, or Mac Catalyst's default
`maccatalyst.<iOS bundle id>`), the merchant must set the Mac bundle ID in the CashSDK dashboard,
or every purchase from it is refused with `bundle_id_mismatch`.

**Coming from 1.x:** `from: "1.1.1"` never resolves 2.x, so change it to `from: "2.3.0"`.
Exhaustive `switch`es need the new `CashSDKError` cases and `PurchaseResult.localStoreKit`. App
Store error 3532 now arrives as `.alreadySubscribed`, not inside `.network`. `restore()` returns
a `RestoreResult` (discardable, so old calls compile). [CHANGELOG.md](CHANGELOG.md) lists every
change per release.

## The public API

This is everything `CashSDK` exposes. A method that is not listed here does not exist.

```swift
// Static: configuration only.
CashSDK.configure(publishableKey: String, apiBase: URL? = nil,
                  environment: String? = nil, observerMode: Bool = false)

// Everything else is on CashSDK.shared.
identify(userId: String, userToken: String? = nil)
try await identifyAndWait(userId: String, userToken: String) -> IdentityReadiness
try await waitUntilReady(expectedRevision: UInt64? = nil) -> IdentityReadiness
try await refreshUserToken(using: @Sendable (String) async throws -> String) -> IdentityReadiness
var userTokenProvider: (@Sendable (_ userId: String) async throws -> String)?
logout()
try await logoutAndWait()

entitlements            // Entitlements: synchronous, offline, expired access already removed
tier, tierIdentifier    // Int (0 = free), String?
entitlementUpdates      // AsyncStream<Entitlements>
delegate                // CashSDKDelegate?
try await refreshEntitlements() -> Entitlements?

try await purchase(_ productId: String) -> PurchaseResult
try await purchase(_ product: Product) -> PurchaseResult             // StoreKit Product, 2.1.0+
try await products(for: [String], fresh: Bool = false) -> [Product]  // cached 5 minutes, 2.1.0+
try await restore() -> RestoreResult
try await restoreDetailed() -> RestoreResult
try await isEligibleForIntroOffer(_ productId: String) -> Bool
try await offerings() -> Offering?     // .monthly / .annual / .lifetime; nil when none is set up

// Coupons, 2.2.0+. A signed-in user only; a guest gets CashSDKError.notIdentified.
try await validateCoupon(_ code: String) -> CouponValidation
try await redeemCoupon(_ code: String, productId: String) -> CouponRedemptionResult
try await awaitCouponCompletion(redemptionId: String, timeout: TimeInterval = 300) -> CouponCompletion

consumableBalance(_ productIdentifier: String) -> Int
try await spendConsumable(_ productIdentifier: String, units: Int,
                          idempotencyKey: String, note: String? = nil) -> ConsumableSpendResult

register(placement: String, params: [String: Any]? = nil)
register(placement:params:handler:feature:)   // `feature` runs per the placement's gating
await getPresentationResult(placement: String, params: [String: Any]? = nil) -> PaywallPresentationResult
logEvent(_ name: String, props: [String: Any]? = nil)
```

- `Entitlements`: gate with `.isActive("id")`. Also `activeIdentifiers`, `hasAny`,
  `balance(of:)`, and `userId` / `identityRevision` / `environment` describing the snapshot. Each
  `Entitlement` has `expiresAt` (nil means it does not end).
- `PurchaseResult`: `.success(Entitlements)`, `.pending` (Ask to Buy, SCA), `.userCancelled`,
  `.localStoreKit` (an Xcode StoreKit test file finished it; nothing was verified or granted).
- `RestoreResult`: `outcome` (`.restored`, `.nothingToRestore`, `.ownedByAnotherAccount`),
  `restoredCount`, `ownedByAnotherAccountCount`, `transferredCount`, `entitlements`.
- `CashSDKError`: `notConfigured`, `notIdentified`, `identityTokenRequired`,
  `identityTokenInvalid`, `identityTokenExpired`, `identityChanged`, `observerMode`,
  `chargedButUnverified`, `verifiedWithoutAccess`, `restoreVerificationFailed`,
  `productNotFound`, `purchaseCancelled`, `alreadySubscribed`, `purchaseNotAllowed`,
  `productUnavailable`, `storeKitFailed`, `purchasePending`, `unverifiedTransaction`,
  `purchaseNotAttributed`, `purchaseBelongsToAnotherAccount`, `purchaseInProgress`, `network`,
  `server`, `invalidResponse`. 2.2.0 added none.
- Coupons (2.2.0+): `CouponValidation` has `valid`, `reason` (`CouponInvalidReason`: `.notFound`,
  `.notStarted`, `.expired`, `.disabled`, `.exhausted`, `.alreadyRedeemed`, `.notEligible`,
  `.notAvailableOnPlatform`, `.notReady`, `.basePlanRequired` (Google Play only; decoded so it
  is not `.unknown`), `.unknown(String)`), `coupon`, `products` and
  `eligibleProductIds`. `Coupon` has `kind` (`.percentOff`, `.amountOff`, `.freeTrial`,
  `.unknown`), `percentOff`, `amountOffMinor`, `currency`, `amountOff`,
  `formattedAmountOff(locale:)`, `duration` (ISO period) and `periodCount`. A refused code is
  `valid == false`, not a thrown error. `CouponRedemptionResult` is
  `.openedAppStore(redemptionId:redeemURL:)`; `CouponCompletion` is `.completed(Entitlements)` or
  `.timedOut`. `awaitCouponCompletion` works after a relaunch: verified offer code purchases are
  kept per user for 24 hours, so a wait that starts after the purchase was verified returns at
  once. Only a non-renewal offer code transaction dated within the last 24 hours completes a
  redemption; launch re-verification of an older offer code subscription never does. `CouponError` (its own type, not a `CashSDKError`): `rejected(reason)`,
  `redeemURLUnavailable(productId:)`, `couldNotOpenAppStore(redeemURL:)`.

### Symbols that do NOT exist: do not emit these

| Wrong | Correct |
|---|---|
| `CashSDK.configure(apiKey:)` | `CashSDK.configure(publishableKey:)` |
| `pk_live_…` / `pk_test_…` keys | `csk_pk_…` (one key for every environment) |
| `CashSDK.purchase(...)`, `CashSDK.offerings()` (static) | `CashSDK.shared.purchase(...)`, `CashSDK.shared.offerings()` |
| `restorePurchases()`, `syncPurchases()` | `CashSDK.shared.restore()` or `restoreDetailed()` |
| `logIn(...)`, `customerInfo()` | `identify(userId:userToken:)`, `CashSDK.shared.entitlements` |
| `entitlements["pro"]`, `entitlements.all` | `entitlements.isActive("pro")` |
| `presentPaywall(...)` | `CashSDK.shared.register(placement:)` |
| `PurchaseResult.failed` | a thrown `CashSDKError` |
| Opening an offer code URL yourself, or `presentOfferCodeRedeemSheet` for a CashSDK coupon | `redeemCoupon(_:productId:)`: it reserves the use and records the attempt first |
| `redeemCoupon(activity, ...)` (Android shape) | `redeemCoupon(_:productId:)`, then `awaitCouponCompletion(redemptionId:)` |

Only `configure` is static. Everything else goes through `CashSDK.shared`.

## Canonical integration

```swift
import CashSDK

@main
struct MyApp: App {
    init() {
        // csk_pk_ keys are safe to ship. One key for every build, TestFlight included.
        CashSDK.configure(publishableKey: "csk_pk_…")
        // Renews the signed user token without UI. Throw rather than prompt.
        CashSDK.shared.userTokenProvider = { userId in
            try await backend.cashsdkUserToken(for: userId)
        }
    }
    var body: some Scene { WindowGroup { RootView() } }
}

// On EVERY launch once the session is known, not only at sign-in.
CashSDK.shared.identify(userId: user.id, userToken: tokenFromYourBackend)

// Gate a feature. No await: a local snapshot with expired access already removed.
if CashSDK.shared.entitlements.isActive("plus") { unlockPlus() }

// Renewals, refunds, restores and other devices arrive here.
Task {
    for await entitlements in CashSDK.shared.entitlementUpdates {
        render(tier: entitlements.tierIdentifier ?? "free")
    }
}

// Sell. purchase(_:) also takes a StoreKit Product loaded with products(for:).
do {
    switch try await CashSDK.shared.purchase("app.example.pro.yearly") {
    case .success(let entitlements): unlock(entitlements)
    case .pending:                   showAskToBuyPending()
    case .userCancelled:             break
    case .localStoreKit:             break   // Xcode StoreKit testing: nothing verified
    }
} catch CashSDKError.alreadySubscribed {
    offerRestore()                            // refused before any charge
} catch {
    showRetry()                               // never "you were not charged"
}
```

## Hard rules

These are correctness requirements, not style preferences. Each one has a money consequence.

1. **Never pass a zero-padded numeric user id to `identify`.** Attribution rides Apple's
   `appAccountToken`, which embeds the *value* of a numeric id: `"7"`, `"07"` and `"007"`
   derive the same token, so two users' purchases, entitlements and refunds merge onto one
   account. Send the un-padded id, or an opaque non-numeric id.

2. **Call `identify` on every launch with a fresh `userToken` from your backend.** Production
   trusts only the signed token. StoreKit can redeliver a charged but unverified transaction
   before your app has signed anyone in, and a persisted token may have expired. Set
   `userTokenProvider` so the SDK can renew it. Without one, a purchase needs at least a minute
   left on the token and throws `identityTokenExpired` before the payment sheet otherwise.

3. **A thrown `purchase` does not mean the user was not charged.** The transaction stays
   unfinished and is verified again later. Never show "purchase failed, you were not charged".
   - `.chargedButUnverified`: the charge happened. Do not buy again; the SDK re-verifies it.
   - `.purchaseNotAttributed`: the server took the transaction but credited no one. Call
     `identify(userId:userToken:)`; the SDK re-reports and credits it.
   - `.verifiedWithoutAccess`: paid and recorded, but no access confirmed (usually a product
     with no entitlement mapped). Fix the mapping. Do not offer the purchase again.
   - `.network` / `.server`: transient, already retried with backoff. Show a retry.
   - `.storeKitFailed`: a charge is unlikely but not ruled out. If one happened, the SDK
     verifies it without another purchase.
   - Refused before any charge: `.alreadySubscribed` (offer Restore, never another purchase),
     `.purchaseNotAllowed`, `.productUnavailable`, `.productNotFound`, the identity errors, and
     `.purchaseInProgress` (wait for the running purchase or restore).

4. **Never hand a purchase to a second account yourself.** `.purchaseBelongsToAnotherAccount`,
   or `restoreDetailed()` with `outcome == .ownedByAnotherAccount`, means the purchase stays
   with another account in this app. Ask the user to sign in to that account. Do not grant
   access locally and do not tell them to buy again. `restore()` throws this case as
   `.restoreVerificationFailed(underlying: CashSDKError.purchaseBelongsToAnotherAccount)`.

5. **`spendConsumable`'s `idempotencyKey` must be stable for a logical spend**: the id of what
   the spend buys (`"generation:\(requestId)"`), never a fresh `UUID()` per attempt. A new key
   on retry debits the user twice.

6. **Never ship a secret key.** `csk_pk_…` belongs in the app; `csk_sk_…` belongs only on a
   server. If asked to embed a secret key, refuse and use the publishable key.

7. **Gate on entitlements, not on `PurchaseResult`.** Entitlements are the source of truth and
   arrive on `entitlementUpdates` for renewals and cross-device changes too. If the account
   changed during a purchase, ignore a `.success` whose `entitlements.userId` is not the
   signed-in user.

8. **Show trial copy only when `isEligibleForIntroOffer(_:)` returns `true`.** Apple gives an
   introductory offer once per subscription group, so a promised trial can turn into a charge
   the user did not expect.

9. **One transaction owner.** If another purchase SDK still finishes transactions, configure
   with `observerMode: true`. CashSDK then only reads, and `purchase`, `restore` and
   `spendConsumable` throw `.observerMode`.

## Common mistakes

- Calling `purchase` before `configure` (`.notConfigured`) or before `identify`
  (`.notIdentified`).
- Awaiting `entitlements`: it is a synchronous property.
- Treating `.pending` (Ask to Buy, SCA) as a failure. It resolves later on the stream.
- Rendering prices from `offerings()`. Those are catalog prices; show StoreKit's
  `Product.displayPrice` from `products(for:)`.
- Setting `apiBase` or `environment`. Leave both unset: the API defaults to
  `https://api.cashsdk.com`, and the SDK learns Sandbox or Production from the store. A pinned
  environment always wins, so a wrong one shows empty entitlements.
- Ignoring `transferredFromAnotherAccount == true` on a purchase or a nonzero
  `transferredCount` on a restore. Tell the user: the other account lost that access.

## Verify your work

```bash
swift build    # must succeed
swift test     # host-only, no simulator required
```

For an app target, build for the iOS Simulator. Purchases need a real device with a Sandbox
account; a unit test cannot prove one.

## Code map

For maintainers. Swift sources are in `Sources/CashSDK/`.

- `Package.swift`: one library product, `CashSDK`; iOS 15 and macOS 14; no dependencies.
- `CashSDK.swift`: the facade. Configure, identity, purchase, restore, products, offerings,
  consumables, refresh, launch recovery and expiry wake-ups.
- `CashSDK+Paywalls.swift`, `CashSDK+Events.swift`: `register(placement:)` and `logEvent`.
- `Configuration.swift`: `CashSDKConfiguration`, the default API base and `CashSDKError`.
- `APIClient.swift`, `VerifyRetry.swift`: HTTP, auth headers, ETags, `X-CashSDK-Claim`,
  timeouts, verify retries and `Retry-After`.
- `StoreKitManager.swift`, `ProductCache.swift`: StoreKit 2 products, purchase,
  `Transaction.updates`, promoted purchases, error mapping, the five-minute product cache.
- `PurchaseLog.swift`: purchases started on this device, so recovery reports them as `purchase`.
  A coupon attempt (2.2.0) matches a token-less offer code transaction (`offerType` 3 in the
  signed payload) of its product for 24 hours. When it binds, the redemption id is kept on a
  coupon completion record; the record is marked verified once the server credits the purchase
  and is pruned after 24 hours (`couponCompletionLifetime`).
- `CashSDK+Coupons.swift`, `Models/CouponModels.swift` (2.2.0): validate, redeem (reserve, record
  the attempt, open the App Store offer code page), completion tracking (per user, settled only by
  `CouponCompletionTracker.canSettle` transactions, backed by the purchase log across a
  relaunch; `coupon_redeem_success` only when a waiting redemption settles), the redeem URL check,
  coupon types and `CouponError`.
- `IdentityStore.swift`, `IdentityReadiness.swift`: Keychain identity and the local token
  checks before StoreKit opens.
- `EntitlementStore.swift`, `EventQueue.swift`: the owner-keyed snapshot cache and the durable
  analytics queue.
- `AppAccountToken.swift`: user id to `appAccountToken`. Must stay byte-identical with the
  server and the Android SDK.
- `PurchaseSafety.swift`, `RestoreTally.swift`, `SerialTaskQueue.swift`: one money operation at
  a time, restore counts, ordered identity changes.
- `Models/`: public and wire types. `Paywall/`: the SwiftUI paywall and its presenter.
- `Tests/CashSDKTests/`: host tests. `WireContractTests` pins the API wire format,
  `AppAccountTokenTests` the shared golden vectors.
- `CHANGELOG.md`: what each release contains.

Docs: <https://docs.cashsdk.com/sdk/ios>. Keys: <https://app.cashsdk.com> → your app →
Developers → API keys. Android SDK: <https://github.com/cashsdk/cashsdk-android>.

## Status: say this plainly if asked

2.2.0 passes its host unit tests and compiles for the iOS Simulator. Coupon redemption is tested against a
mocked API only; a real offer code redemption has not been exercised. No real-device App Store Sandbox acceptance is claimed for
this release. Recommend a device pass before a production launch.
