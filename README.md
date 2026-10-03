<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://assets.cashsdk.com/brand/wordmark-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://assets.cashsdk.com/brand/wordmark.svg">
  <img alt="CashSDK" src="https://assets.cashsdk.com/brand/wordmark.svg" width="360">
</picture>

### In-app purchases that take four lines.

StoreKit 2 purchases, cross-device entitlements and server-driven paywalls,
without receipts, transaction plumbing, or a backend of your own.

[![Swift Package Manager](https://img.shields.io/badge/Swift_Package_Manager-compatible-24A47F)](https://github.com/cashsdk/cashsdk-ios)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS_15%2B_%7C_macOS_14%2B-15372C)](#requirements)
[![Tests](https://img.shields.io/badge/tests-176_passing-24A47F)](Tests)
[![Dependencies](https://img.shields.io/badge/dependencies-0-15372C)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[Documentation](https://docs.cashsdk.com/sdk/ios) ·
[Dashboard](https://app.cashsdk.com) ·
[API reference](https://docs.cashsdk.com) ·
[Android SDK](https://github.com/cashsdk/cashsdk-android)

</div>

---

## Install

The current release is **2.3.0**. One package covers iPhone, iPad, the Mac (native macOS and
Mac Catalyst) and the Mac App Store. In Xcode: **File → Add Package Dependencies…**, paste the URL,
and add `CashSDK` to your app target.

```
https://github.com/cashsdk/cashsdk-ios
```

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/cashsdk/cashsdk-ios.git", from: "2.3.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "CashSDK", package: "cashsdk-ios")
    ])
]
```

No other dependencies are pulled in.

### Upgrading from 1.x

`from: "1.1.1"` stays on 1.x, so change it to `from: "2.3.0"`. Exhaustive `switch`es need the
`CashSDKError` cases added since 1.1.1 and `PurchaseResult.localStoreKit`. App Store error 3532
("already subscribed") used to arrive as `.network(underlying:)`. Match `.alreadySubscribed`
instead:

```swift
// 1.x: catch CashSDKError.network(let underlying) where underlying was App Store error 3532
catch CashSDKError.alreadySubscribed(let productId) { askBeforeClaiming(productId) }
```

Automatic recovery now also reports purchases that carry no app account token (offer codes
redeemed in the App Store, promoted and family-shared purchases). One that no account owns yet
goes to whichever account is signed in on the device, as it already did on a manual Restore;
one another account owns stays with it. [CHANGELOG.md](CHANGELOG.md) has the full list.

## Quick start

```swift
import CashSDK

// 1. Once at launch. Publishable keys are safe to ship in your binary.
CashSDK.configure(publishableKey: "csk_pk_…")

// 2. When you know who the user is.
CashSDK.shared.identify(userId: "8841", userToken: tokenFromYourBackend)

// 3. Gate a feature. Synchronous, offline-valid, no await.
if CashSDK.shared.entitlements.isActive("plus") {
    unlockPlus()
}

// 4. Sell.
let result = try await CashSDK.shared.purchase("app.example.pro.yearly")
```

Get your publishable key from the [dashboard](https://app.cashsdk.com) → your app →
**Developers → API keys**.

### Reacting to changes

Renewals, refunds, restores and cross-device purchases all arrive on one stream:

```swift
for await entitlements in CashSDK.shared.entitlementUpdates {
    render(tier: entitlements.tierIdentifier ?? "free")
}
```

…or set `CashSDK.shared.delegate` and implement `CashSDKDelegate`.

### Paywalls

Present the paywall your team configured in the dashboard, for a named placement. Fire and
forget: if there's no campaign, the device is offline, or the config is bad, it silently
advances. Your app is never blocked by a paywall it couldn't load.

```swift
CashSDK.shared.register(placement: "onboarding_finished")
```

## macOS and the Mac App Store

The same package and API run in native macOS apps (AppKit or SwiftUI, macOS 14+) and in Mac
Catalyst builds. Add the **In-App Purchase** capability to the macOS target and configure with
the same publishable key as your iOS app.

- **Paywalls**: from 2.3.0, `register(placement:)` presents the dashboard paywall natively on the
  Mac, as a sheet on the key window or in its own window. Mac Catalyst presents it like iPad.
- **Universal purchase**: a Mac build that shares the iOS bundle ID and App Store Connect record
  needs nothing else. Tick **macOS** as a platform in the CashSDK dashboard.
- **A separate Mac App Store record** (its own bundle ID, or Mac Catalyst's default
  `maccatalyst.<iOS bundle ID>`): set the **Mac bundle ID** and **Mac Apple App ID** in the
  dashboard, paste the same notification URL into the Mac record, and map its products (store
  `mac-app-store`) to the same entitlements.
- The SDK reports `platform: "macos"` on the Mac, so Mac customers are told apart in the
  dashboard.

Full guide: [docs.cashsdk.com/sdk/macos](https://docs.cashsdk.com/sdk/macos).

## Requirements

| | |
|---|---|
| **Platforms** | iOS 15+, macOS 14+ |
| **Swift** | 5.9+ (`swift-tools-version: 5.9`) |
| **Xcode** | 15+ |
| **Dependencies** | none (StoreKit, SwiftUI and Foundation only) |
| **Concurrency** | builds under `-strict-concurrency=complete` with two known warnings in `CashSDK+Paywalls.swift` |

## What you get

| | |
|---|---|
| **Purchases** | StoreKit 2 end to end: subscriptions, one-time purchases, and consumables with a server-held balance. |
| **Server-verified entitlements** | Every transaction is validated against Apple by the CashSDK API, so a jailbroken device can't grant itself Pro. |
| **Cached reads** | `entitlements` reads the last server snapshot without awaiting the network. A new purchase still requires server verification; there is no StoreKit-local fallback grant. |
| **Cross-device & cross-platform** | The same user's entitlements resolve on their iPhone, iPad and Mac, and on Android through the [Android SDK](https://github.com/cashsdk/cashsdk-android). |
| **Server-driven paywalls** | Change copy, pricing, layout and experiments from the dashboard without an App Store release. |
| **Attribution that survives** | Purchases are bound to your user id through Apple's `appAccountToken`, derived identically on iOS, Android and the server. |
| **Analytics** | Paywall and purchase funnel events are batched and durably queued, so they survive a cold launch. |

---

## Integration rules that bite

Four things that are easy to get wrong and expensive to discover in production.

**Pass un-padded user ids to `identify(userId:)`.** The `appAccountToken` that carries
attribution embeds the *value* of a numeric id, so `"7"`, `"07"` and `"007"` all derive the
**same** token on iOS, on Android and on the server alike (that byte-parity is the point;
changing it on one side would drop attribution for every existing purchase). A backend that
emits zero-padded ids will therefore merge two users' purchases, entitlements and refunds onto
one account. Send the un-padded id, or use an opaque non-numeric id: those hash every byte and
never collide this way.

**Identify on every launch.** The SDK persists the last identity (in the Keychain) so it can
report a charged-but-unverified purchase that StoreKit redelivers at launch, before your app has
signed anyone in. A persisted `userToken` can still have expired, so re-identify with a fresh one.

**A purchase is never finished before the server has recorded it.** If `purchase(_:)` throws,
the transaction is deliberately left unfinished and StoreKit will redeliver it. Do not treat a
thrown error as "the user was not charged". These cases are worth handling by name:

| Error | Meaning | What to do |
|---|---|---|
| `.purchaseNotAttributed` | The server accepted the transaction but could not credit it to anyone (a promoted App Store purchase, or one made before `identify`). | Call `identify(userId:userToken:)`. The SDK re-reports and credits it automatically. |
| `.network` / `.server` (5xx) | Transient. Already retried with backoff, plus a bounded in-session redrain. | Show a retry affordance; the SDK also recovers on its own. |
| `.alreadySubscribed` | The App Store refused before charging: this Apple ID already has the subscription, usually under another account in your app. Before 2.0.0 it arrived as `.network(underlying:)` carrying error 3532; match this case instead. | Offer Restore Purchases, or ask the user to sign in to the account that subscribed. Never offer another purchase. |

**Sandbox vs Production.** Ship the same publishable key everywhere, including TestFlight.
There is one `csk_pk_…` per app and it works in both environments, because TestFlight
distributes the exact binary you submit to the App Store while its purchases run in Apple's
sandbox: a key pinned to one environment would lock out every user of the other.

Entitlements still resolve per environment, and the SDK works out which one it is on its own:
from `Transaction.environment` on iOS 16+, and from the server's verify response on iOS 15. It
then sends `X-CashSDK-Environment` on subsequent reads. Pin it explicitly with
`CashSDK.configure(publishableKey:apiBase:environment:)` only when a QA build must read Sandbox
before it has made any purchase at all; a pinned value always wins, so a wrong one shows an
empty entitlement list.

## SwiftUI gating

```swift
struct RootView: View {
    @State private var entitlements = CashSDK.shared.entitlements

    var body: some View {
        Group {
            if entitlements.isActive("plus") { ProContent() } else { FreeContent() }
        }
        .task {
            for await update in CashSDK.shared.entitlementUpdates { entitlements = update }
        }
    }
}
```

## Consumables

Balances are held server-side, so they survive reinstalls and follow the user across devices.

```swift
let credits = CashSDK.shared.consumableBalance("credits")

try await CashSDK.shared.spendConsumable(
    "credits",
    units: 5,
    idempotencyKey: "generation:\(requestId)"   // see below
)
```

`idempotencyKey` must be **stable for a given logical spend**: the id of whatever the spend
buys (a level unlock, a generation request), *not* a fresh `UUID()` per attempt. A new key on
every retry is how you debit a user twice for one action.

## Coupons

From 2.2.0. A merchant creates a coupon code in the dashboard (percent off, amount off, or a free
period, limited to chosen plans). On iOS each coupon is an App Store offer code, so Apple applies
the discount. The user types the code in your app; the SDK opens the App Store's offer code page
with it filled in.

```swift
let check = try await CashSDK.shared.validateCoupon(codeField.text ?? "")
guard check.valid, let coupon = check.coupon, let plan = check.eligibleProductIds.first else {
    return showError(check.reason.map { CouponError.rejected($0).localizedDescription } ?? "")
}
showOffer(coupon)   // kind, percentOff, formattedAmountOff(), duration, periodCount

let redemption = try await CashSDK.shared.redeemCoupon(coupon.code, productId: plan)
// The App Store is now open. When the user comes back:
switch try await CashSDK.shared.awaitCouponCompletion(redemptionId: redemption.redemptionId) {
case .completed(let entitlements): unlock(entitlements)
case .timedOut: break   // a later purchase still arrives on entitlementUpdates
}
```

- Both calls need a signed-in user (`identify`); a guest gets `CashSDKError.notIdentified`.
- A refused code is `valid == false` with a `CouponInvalidReason`, never a thrown error.
- `redeemCoupon` reserves one use (the same user and coupon always get the same reservation),
  records the attempt, and opens the offer code page. The purchase arrives through
  `Transaction.updates` and is verified with claim `purchase` like any purchase made in the app,
  even after a relaunch. It is a money operation: it throws `purchaseInProgress` while a purchase
  or restore runs.
- `awaitCouponCompletion` also works after a relaunch (the app killed while the user was in the
  App Store): verified offer code purchases are kept per user for 24 hours, so a wait that starts
  after the purchase was verified returns `.completed` at once.
- Only a new offer code purchase (not a renewal, dated within the last 24 hours) completes a
  redemption. Re-verifying an older offer code subscription at launch never does.
- Only an `https://apps.apple.com/redeem` URL from the server is opened.
- `CouponError` (`rejected`, `redeemURLUnavailable`, `couldNotOpenAppStore`) is its own type, so
  exhaustive switches over `CashSDKError` still compile.

---

## Server REST contract

Base URL defaults to `https://api.cashsdk.com` (override via `apiBase`). Every device
request sends `Authorization: Bearer <publishableKey>` and, once identified,
`X-CashSDK-User-Token`.

| Method & path | Purpose |
|---|---|
| `POST /v1/transactions:verify` | Body `{ "signedTransaction": "<JWS>" }` (StoreKit 2 `Transaction.jwsRepresentation`). Returns the fresh entitlement snapshot. Called for every `Transaction.updates` and after a purchase. Sends `If-None-Match`; captures the response `ETag`. Also sends `X-CashSDK-Claim: purchase \| restore \| sync` (only `purchase` and `restore` may move a purchase between app accounts) and reads `transferredFromAnotherAccount`. |
| `GET /v1/entitlements` | Returns `{ entitlements: [{identifier, name, rank, source}], tier, tierIdentifier }`. Sends `If-None-Match` → `304` when unchanged (cache kept). |
| `POST /v1/events` | Body `{ "events": [{ event, placement?, paywall?, variant?, product?, props?, ts? }], "platform": "ios" | "macos", "appVersion"? }`. Buffered + batched telemetry (`paywall_open`, `purchase_start`, `purchase_success`, …). `202 Accepted`. |
| `POST /v1/coupons:validate` | Body `{ code, appUserId, platform: "ios" | "macos" }`. Returns `{ valid: true, coupon, products: [{ productIdentifier, ios?: { appleCode, redeemUrl } }] }` or `{ valid: false, reason }`. |
| `POST /v1/coupons:redeem` | Body `{ code, appUserId, platform: "ios" | "macos", productIdentifier }`. Returns `{ redemptionId, ios: { appleCode, redeemUrl } }`; the same reservation for a repeat call. |
| `GET /v1/paywalls:resolve?placement=<p>` | Returns `{ paywall: { config: <json> } \| null, variantId?, experimentId? }`. The server resolves app + campaign + audience from the key (+ user). `register()` calls this. |

**Entitlement snapshot** (returned by both `verify` and `entitlements`):

```json
{
  "entitlements": [{ "identifier": "plus", "name": "Plus", "rank": 1, "source": "subscription" }],
  "tier": 1,
  "tierIdentifier": "plus"
}
```

`tier` is the numeric rank of the highest active entitlement (`0` = free); `tierIdentifier`
is its string id (or `null`).

**Paywall config** is the `schema_version: 2` component tree emitted by the dashboard's AI
builder / seed templates. The renderer understands: `stack`, `text`, `image`,
`feature_list`, `product_selector`, `timer`, `carousel`, `comparison_table`, `badge`,
`button`, `divider`, `spacer`, plus `theme` (accent/background/text/corner_radius/dark_mode)
and role→product mapping (`primary` / `secondary`). Unknown types and missing fields render
as nothing.

## Architecture

```
CashSDK (facade / singleton)         Public API + coordination; lock-guarded snapshot for
  │                                   synchronous `entitlements` reads; event batching.
  ├── APIClient          (actor)      URLSession async, Bearer + user headers, ETag store.
  ├── EntitlementStore   (actor)      In-memory + on-disk Codable cache (Application Support).
  ├── StoreKitManager    (class)      Product loading, purchase, Transaction.updates listener.
  └── Paywall
        ├── PaywallPresenter (@MainActor)  Presents over the key window; lifecycle events.
        └── PaywallView       (SwiftUI)    Renders the component-tree config.
```

**Concurrency:** `APIClient` and `EntitlementStore` are actors. UI-touching code
(`PaywallPresenter`, `PaywallView`) is `@MainActor`. `CashSDK.entitlements` is served from a
mutex-guarded snapshot so it can be read synchronously from any thread. Purchase reporting is
idempotent server-side, so the launch backstop and the updates listener can't double-grant.

**Offline reads:** entitlement reads use the last cached server snapshot without awaiting
the network. There is no StoreKit-local entitlement fallback for a newly charged purchase
whose server verification failed. That transaction stays unfinished for retry; do not tell
the user that a thrown error means they were not charged.

---

## Status

**Implemented and tested**

- **Public API**: `configure`, `identify` / `logout`, `purchase`, `products(for:)`, `restore` /
  `restoreDetailed`, `register`, `entitlements`, `entitlementUpdates` / `delegate`,
  `userTokenProvider`, `isEligibleForIntroOffer`, `consumableBalance`, `spendConsumable`,
  and from 2.2.0 `validateCoupon`, `redeemCoupon`, `awaitCouponCompletion`.
- **StoreKit 2 engine**: `Product.products(for:)`, `product.purchase(options:)` with a derived
  `appAccountToken`, the `Transaction.updates` listener, the `currentEntitlements` backstop,
  `AppStore.sync()` restore, and unverified/pending/cancelled classification.
- **`appAccountToken` byte-parity** with the server and the Android SDK, pinned by shared
  golden vectors.
- **User token (Mode B)**: `identify(userId:userToken:)` sends the backend-minted signed token
  as `X-CashSDK-User-Token`, the only identity production trusts.
- **Offline-first entitlement cache** plus a durable, atomically-persisted event queue:
  telemetry survives a cold launch, and a drop is accounted for rather than silently lost.
- **Delivery guarantees**: a purchase is never finished before the server records it, so an
  undelivered verify is redelivered by StoreKit at next launch; transient failures also get a
  bounded in-session retry with exponential backoff.
- **202 unit tests** (`swift test`, host-only, no simulator required) covering token derivation,
  the owner-keyed entitlement cache, verify attribution, identity-mutation ordering, event-queue
  durability, wire-contract decoding, StoreKit error mapping, restore results, expiry refresh,
  token renewal, `Retry-After`, the verify claim header, the product cache and coupons.

**Open**

- **No device or live-Sandbox pass yet.** Every path above is compile- and unit-verified against
  synthetic payloads. Keychain behaviour and a real App Store Sandbox purchase
  (verify → lifecycle → entitlement → webhook) still want one run on hardware before a
  production launch.
- **Asset resolution.** `image.asset_id` renders placeholder art; wiring it to the asset CDN and
  a bundled `CashSDKFallback.json` for first-launch-offline is not done.
- **No UIKit entry point.** `register(placement:)` presents from SwiftUI over the key window;
  the `presentPaywall(from:)` UIKit convenience is not implemented.

## Contributing

This repository is published from the CashSDK source tree, so edits made directly here are
overwritten by the next release. Send changes as a pull request or an issue instead. For
anything security-related, please email **security@cashsdk.com** rather than opening a public
issue.

```bash
git clone https://github.com/cashsdk/cashsdk-ios.git
cd cashsdk-ios
swift test
```

## License

MIT. See [LICENSE](LICENSE).

<div align="center">
<br>
<sub>Built by the CashSDK team · <a href="https://cashsdk.com">cashsdk.com</a></sub>
</div>
