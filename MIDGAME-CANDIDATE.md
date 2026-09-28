# Midgame integration contract (historical)

> This contract shipped in `2.0.0` (2026-09-26). Install the current release, `from: "2.2.0"`;
> README.md and AGENTS.md describe it. The notes below are kept as the candidate's record.

> Plan XYZ TestFlight candidate: `1.2.0-rc.1`. Install with an **exact** SwiftPM version.
> This prerelease adds the September identity and purchase safeguards described below.
> It has passed host tests and simulator compilation, but real-device Sandbox purchases
> and App Store approval remain pending. Stable installations remain on `1.1.1`.


This file describes the monorepo candidate, not published 1.1.1. A release engineer must
publish an immutable version, record its revision, update installation coordinates, and
verify a clean consumer build before Midgame changes its pin. Deploy the accompanying
server response contract and webhook-attempt migrations before candidate checkout.

## Identity and transaction ownership

`identifyAndWait(userId:userToken:)` returns `IdentityReadiness(userId, revision)` after
the same identity is installed for verification and cache ownership. It does not promise
an online entitlement refresh; call `refreshEntitlements()` explicitly when needed.
`waitUntilReady()` supports the existing synchronous identify call. Purchase and restore
wait internally. A superseding login/logout causes a pending readiness call to throw.

`refreshUserToken(using:)` calls an async host token issuer. Readiness is revoked before
the callback; failed or late callbacks cannot reinstall an older session.
`logoutAndWait()` clears access and completes identity teardown. Re-authenticate every
launch. Missing, expired and mismatched JWTs are rejected locally before StoreKit; server
signature verification remains authoritative. Unsigned identities work only on loopback.

A purchase captures its user, token, revision and API client before StoreKit. Login changes
cannot rewrite the buyer on its verification request. Hosts must ignore a completed A
purchase in B's UI; use the returned `userId`/`identityRevision`. Automatic recovery only
claims purchases carrying the current account's canonical StoreKit token. Explicit restore
can submit older purchases, subject to the server's policy. Midgame keeps original owners
until its review. Never grant a second account or instruct a customer to repurchase.

## September 23 source additions (after `1.2.0-rc.1`)

Deploy the matching API first: it reads `X-CashSDK-Claim` and returns
`transferredFromAnotherAccount`.

**Migration for Midgame.** App Store error 3532 ("already subscribed") used to arrive as
`CashSDKError.network(underlying:)`, which is what `isAlreadySubscribedStoreError` searches.
It is `.alreadySubscribed(productId:)` now, so that search finds nothing and the "ask before
claiming" prompt stops appearing until the match changes:

```swift
// Before: catch CashSDKError.network(let underlying) where isAlreadySubscribedStoreError(underlying)
catch CashSDKError.alreadySubscribed(let productId) { askBeforeClaiming(productId) }
```

- `userTokenProvider` mints a fresh token for the signed-in user from your backend, without
  UI. The SDK calls it when a purchase would open the App Store sheet with less than five
  minutes left on the token, when a purchase, restore or entitlement refresh finds the token
  expired, and once after the server rejects the token (the call is then retried once).
  Without a provider, or when the provider fails, a purchase still goes ahead with at least
  a minute left, as with `1.2.0-rc.1`, and logs a warning; under a minute it throws
  `identityTokenExpired` before the sheet. That minute is checked again right before the
  sheet opens. The identity revision does not change, so the revision check in the example
  still matches.
- `restoreDetailed()` returns a `RestoreResult`: `restoredCount`,
  `ownedByAnotherAccountCount`, `transferredCount`, `outcome` and the `entitlements` after
  the restore. `restore()` returns the same result but, for existing callers, still throws
  when every purchase found belongs to another account.
- `isEligibleForIntroOffer(_:)` answers from StoreKit whether this Apple ID can still get the
  product's introductory offer. Show trial copy only when it returns `true`.
- `transferredFromAnotherAccount == true` on the entitlements of a purchase result means the
  server moved that purchase here from another app account under the `transfer` restore
  policy. Tell the user; restore results count these in `transferredCount`. It is delivered
  once, with that result, and never appears on `entitlements` or the stream.
- Refusals before any charge are typed: `alreadySubscribed(productId:)` (App Store error
  3532), `purchaseNotAllowed`, `productUnavailable(productId:)`. `storeKitFailed` means
  StoreKit returned no transaction for another reason; a charge is unlikely but not ruled
  out, and one that happened is verified on its own.
- Every verify sends `X-CashSDK-Claim`: `purchase`, `restore`, or `sync` for anything
  automatic. Recovery reports a purchase started on this device for the signed-in user
  (a verify that did not land, an approved Ask-to-Buy, an app killed mid-payment) as
  `purchase`, so under the `transfer` policy a returning customer's resubscribe is credited
  even when its first verify failed. Renewals never count as that purchase, so a renewal can
  never take a chain back from the account a `transfer` restore gave it to; renewals and
  purchases made elsewhere stay `sync`. The record names nobody (an HMAC of the user id under
  a per-install secret), is not backed up, and is kept across logout so an Ask to Buy approved
  while the buyer is signed out still counts when they sign back in.
- `sync` never moves ownership, so automatic recovery now also reports transactions without
  an app account token (offer codes, promoted and family-shared purchases). Deliberately, one
  that no account owns yet goes to whichever account is signed in on the device, as a manual
  Restore already did.
- A few random seconds after an entitlement's `expiresAt` the SDK asks the server first and
  publishes its answer, so a renewed subscription does not flicker. When the server cannot be
  asked within 10 seconds (token renewal included), the access ends on the stream, with
  bounded, jittered retries that respect `Retry-After` while the app is in the foreground.
  Cached access loads before the token check, so an offline launch keeps it.

```swift
CashSDK.shared.userTokenProvider = { userId in
    try await backend.cashsdkUserToken(for: userId) // Throw rather than prompt.
}
```

## Example for the released successor

This function is suitable for a test harness against the candidate source. The shipping
app must use the eventual immutable release; do not replace Midgame's pin with a branch.

```swift
import CashSDK

func authenticateMidgame(userId: String, tokenFromBackend: String) async throws -> IdentityReadiness {
    let ready = try await CashSDK.shared.identifyAndWait(
        userId: userId, userToken: tokenFromBackend
    )
    _ = try await CashSDK.shared.refreshEntitlements()
    return ready
}

// Configure once before authentication. During a RevenueCat comparison, observerMode
// must be true and RevenueCat remains the sole transaction owner.
CashSDK.configure(publishableKey: publishableKey, observerMode: true)

```

In a separately approved CashSDK checkout build, configure `observerMode: false`
once at launch. The purchase handler then uses the identity revision:

```swift
// Resolve the three product ids through StoreKit; display Product.displayPrice and
// only offer a trial when CashSDK.shared.isEligibleForIntroOffer(productId) is true.
let ready = try await authenticateMidgame(userId: user.id, tokenFromBackend: signedToken)
switch try await CashSDK.shared.purchase(selectedStoreProduct.id) {
case .success(let access):
    guard access.userId == ready.userId,
          access.identityRevision == ready.revision else { break }
    renderAccess(access)
case .pending:
    showPendingPayment()
case .userCancelled:
    break
case .localStoreKit:
    showLocalTestCompletion() // No server access was verified.
}
```

Catch `chargedButUnverified` without claiming that no charge occurred. Preserve the
unfinished transaction and show recovery feedback. `verifiedWithoutAccess` means durable
attribution succeeded but the exact purchase did not confirm access; investigate mapping
and lifecycle evidence. `purchaseBelongsToAnotherAccount` preserves original ownership.
Restore errors are wrapped as `restoreVerificationFailed(underlying:)`; inspect the cause
for ownership conflict, or call `restoreDetailed()` to get it as
`outcome == .ownedByAnotherAccount`. Pre-charge identity errors, `alreadySubscribed`,
`purchaseNotAllowed`, `productUnavailable`, pending and cancellation are distinct.

Do not gate access from the fact that purchase returned. Use active entitlements and the
protected backend's independently resolved access. `expiresAt` bounds cached access;
`computedAt`, `version`, `environment`, `userId` and `identityRevision` explain the snapshot.

## Verification still required

Host tests and a generic simulator build do not prove a payment. Record the released
revision and real Sandbox device evidence for every Midgame plan, trial eligibility,
A→B→A, logout during payment, expired refresh, network/process interruption, reinstall,
restore, cancellation/pending, renewal/grace, refund/revocation and backend protected access.
Confirm the new server response contains `purchaseOutcomeConfirmed`; older servers cannot
certify candidate purchase success. Observer mode must never settle RevenueCat transactions.
