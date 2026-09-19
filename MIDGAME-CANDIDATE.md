# Midgame integration contract — unreleased source

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
// only offer a trial when StoreKit reports eligibility for its subscription group.
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
for ownership conflict. Pre-charge identity errors, pending and cancellation are distinct.

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
