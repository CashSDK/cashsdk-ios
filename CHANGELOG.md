# Changelog

## 2.2.0 (2026-09-28): coupons

Additive. No `CashSDKError` case was added, so exhaustive switches still compile.

- `validateCoupon(_:)` calls `POST /v1/coupons:validate` with the signed-in user and
  `platform: "ios"`. It returns a `CouponValidation`: `valid`, a `CouponInvalidReason`
  (`notFound`, `notStarted`, `expired`, `disabled`, `exhausted`, `alreadyRedeemed`,
  `notEligible`, `notAvailableOnPlatform`, `notReady`, `basePlanRequired` (sent for Google Play
  coupons with several base plans; decoded rather than left as unknown), and `unknown(String)`
  for a reason a newer server adds), the `Coupon` (kind, percent off, amount off in minor units with `amountOff` and
  `formattedAmountOff(locale:)`, duration, period count) and the products that have an iOS offer
  code. A refused code is a result, not a thrown error. Codes are trimmed and upper-cased.
- `redeemCoupon(_:productId:)` reserves one use with `POST /v1/coupons:redeem`, records the
  attempt, and opens the App Store offer code page (`UIApplication.open` on the main actor,
  `NSWorkspace` on macOS). It returns `.openedAppStore(redemptionId:redeemURL:)`. It is a money
  operation: one at a time with purchase and restore. Only an `https://apps.apple.com/redeem`
  URL is opened, with `code` set to the reservation's Apple code.
- The resulting transaction arrives through `Transaction.updates` with no app account token and
  `offerType` 3. The purchase record matches it to the coupon attempt for 24 hours (the
  reservation's lifetime), so it is verified with claim `purchase`, also after a relaunch.
  Renewals, other products, other accounts' transactions and purchases dated before the attempt
  stay `sync`.
- `awaitCouponCompletion(redemptionId:timeout:)` returns `.completed(Entitlements)` once that
  purchase is verified for the signed-in user, or `.timedOut`. It works across a relaunch: the
  purchase record keeps each verified offer code purchase for 24 hours, per user, with the
  redemption ids it settles when known, so a wait that starts after the purchase was verified
  returns at once. Waiters are kept per user; another user on the device never sees them.
- Only an offer code transaction that is not a renewal and is dated within the last 24 hours
  (the reservation window) completes a redemption. Launch recovery re-verifies current
  subscriptions, including one bought with an offer code weeks ago and still on its discounted
  periods; that never completes a new redemption.
- Analytics: `coupon_redeem_start` when the App Store opens; `coupon_redeem_success` only when a
  verified purchase settled a redemption that was waiting, once per purchase. An offer code
  purchase nobody was waiting for, or a redelivered transaction, records no success.
- New `CouponError`: `rejected(reason)` when the server refuses the code while reserving it,
  `redeemURLUnavailable(productId:)`, `couldNotOpenAppStore(redeemURL:)`.
- Guests are refused with `CashSDKError.notIdentified` before any request. `429` and `503` are
  retried honouring `Retry-After` up to 30 seconds, and other transient failures with backoff;
  the reservation is idempotent server side, so a retry or a second tap gets the same one.
- Amount-off formatting uses the server's ISO 4217 exponents (JPY and KRW have none, KWD three).
- 202 host tests (176 before) and a generic iOS Simulator build.

## 2.1.0 (2026-09-26): purchase a `Product` you already hold

Additive. Two entry points for an app that renders its own paywall from StoreKit:

- `purchase(_ product: Product)`: the same flow and errors as `purchase(_ productId:)`, minus
  the product lookup. The sheet opens with the `Product` passed in, and that product goes into
  the SDK's cache for a promoted purchase or a later `purchase(_ productId:)` to find.
- `products(for:fresh:)`: StoreKit `Product`s with localized prices, cached for five minutes in
  the same cache the Buy tap reads. Before this, only the SDK's own paywall render filled that
  cache, so an app loading plans with `Product.products(for:)` directly still paid for a second
  lookup on the tap.

## 2.0.0 (2026-09-26): purchase, trial, restore and returning-customer fixes

**Major, because exhaustive switches over `CashSDKError` will not compile.** Four cases were
added (see the first entry below). `from: "1.1.1"` resolves within 1.x, so nothing upgrades into
this by itself: moving to it is an explicit change to `from: "2.0.0"`.

Also in this release: the client no longer uses `URLSession.shared`. It builds its own session
with a 15-second request timeout and a 60-second resource timeout, so a verify meeting a network
that accepts the connection and then goes quiet gives up in seconds rather than the three minutes
`URLSession.shared` allowed across three retry attempts.

Deploy the matching API first: it reads `X-CashSDK-Claim` and returns `transferredFromAnotherAccount`.

> **Migration: App Store error 3532 is `.alreadySubscribed` now, not `.network`.**
> In `1.2.0-rc.1`, "this Apple ID is already subscribed" (App Store error 3532) arrived as
> `CashSDKError.network(underlying:)`, so hosts searched the underlying error for 3532 (Midgame's
> `isAlreadySubscribedStoreError`, for one). That search now finds nothing, and a prompt shown on
> it silently stops appearing. Match the typed case instead:
>
> ```swift
> // Before: catch CashSDKError.network(let underlying) where isAlreadySubscribedStoreError(underlying)
> catch CashSDKError.alreadySubscribed(let productId) { askBeforeClaiming(productId) }
> ```

- StoreKit errors are typed instead of all becoming `.network`. New `CashSDKError` cases for refusals that come before any charge: `alreadySubscribed(productId:)` (App Store error 3532: the Apple ID already has this subscription, usually under another app account), `purchaseNotAllowed` and `productUnavailable(productId:)`. `storeKitFailed(underlying:)` covers any other StoreKit failure, including a purchase result this SDK does not recognize, which used to read as a cancellation. A cancellation that StoreKit throws returns `.userCancelled`. Exhaustive switches over `CashSDKError` need the new cases. The message for `productUnavailable` does not include the product id; the id stays in the payload and the log.
- The built-in paywall says what happened. Failures before the App Store sheet no longer say "payment may have completed", and a restore that finds another account's purchases says so instead of blaming the connection.
- `restore()` returns a `RestoreResult` and is `@discardableResult`, so existing calls compile. The result has restored, transferred and other-account counts, an `outcome` (`.restored`, `.nothingToRestore`, `.ownedByAnotherAccount`) and the entitlements after the restore. `restore()` still throws `restoreVerificationFailed(underlying: purchaseBelongsToAnotherAccount)` when every purchase found belongs to another account. New `restoreDetailed()` returns that case as a result. Cancelling the App Store sign-in during a restore throws `purchaseCancelled`.
- `entitlementUpdates` and the delegate only publish unexpired entitlements, with the tier recomputed from them. A few random seconds after the earliest future `expiresAt` (one wake-up, replaced by every new snapshot, spread so devices do not all ask at once) the SDK asks the server first, for a full answer (no `If-None-Match`) and with the token renewed through `userTokenProvider` when needed, and publishes that answer, so a subscription the server has renewed does not flicker off and on. When the server cannot be asked within 10 seconds (the provider included), the access ends on the stream (fail closed) and the refresh is retried up to six times, with full jitter from 5 s doubling to 5 minutes and never before a `Retry-After`, while the app is in the foreground (`.inactive` counts). An answer that arrives after the timeout still applies. No client leeway: the server's `expiresAt` already includes the renewal grace for auto-renewing subscriptions. The synchronous `entitlements` read is fail closed at `expiresAt` too, for the moment the refresh takes.
- `identify` serves the user's cached entitlements before checking the token, so an offline launch with an expired token keeps its access. Identifying the same user again no longer publishes an empty snapshot first.
- New `userTokenProvider`. When set, the SDK calls it to renew a token before a purchase with less than five minutes left, when a purchase, restore or entitlement refresh finds the token expired, and when the server rejects the token (`401 invalid_user_token` on a verify, `401 unauthenticated_user` on a read), after which the call is tried once more. The identity revision stays the same. If the provider fails, a purchase still goes ahead with the current token when it has at least 60 seconds left, as it would without a provider. Without a provider, a purchase goes ahead with at least 60 seconds left on the token, as `1.2.0-rc.1` hosts expect, and logs a warning below five minutes; under 60 seconds it throws `identityTokenExpired` before the App Store sheet. The 60-second floor is checked again right before the sheet opens, after the product lookup. A transaction whose verify fails stays unfinished and is recovered later.
- A `429` or `503` verify with `Retry-After` of 30 seconds or less is retried after that wait, with jitter. A longer one leaves the transaction unfinished for a recovery pass scheduled after it, and automatic reports pause until then.
- Every `POST /v1/transactions:verify` sends `X-CashSDK-Claim`: `purchase` right after a purchase in this app (a promoted one included), `restore` for `restore()` and `restoreDetailed()`, and `sync` for everything automatic, with one exception below.
- Recovery reports the buyer's own purchase as `purchase`, not `sync`. The SDK keeps a small per-user record, on disk, of purchases started on this device: the product and start time, written before the payment sheet opens, then the transaction id once StoreKit returns it. When recovery (the launch and foreground passes, the scheduled retry, the `Transaction.updates` listener) reports a transaction with that id, or the first one for that product that carries the user's own app account token, is dated after the start and is not a renewal (an approved Ask-to-Buy or SCA purchase, or a purchase whose app was killed mid-payment), it sends `purchase`. Without this, under restore policy `transfer`, a returning customer's resubscribe whose first verify did not land was never credited and never finished. Renewals (`Transaction.reason`, or the signed payload's `transactionReason`), purchases made elsewhere and other users' transactions stay `sync`. On iOS 15 and 16, when the payload does not say whether it is a renewal, a transaction that continues an existing chain only counts for an attempt StoreKit left pending; there, a resubscribe completed after an app kill or a failed sheet goes out as `sync`. When a transaction matches, the product's other attempts (a second tap) are dropped. The record is cleared once the server credits the transaction; attempts expire after 7 days (StoreKit does not report a declined Ask to Buy, so its attempt runs out) and transaction ids after 30.
- The purchase record stores no user id and no app account token. Records are keyed by an HMAC of the user id under a random per-install secret kept in a file next to them. Both files are excluded from backup and readable once the device has been unlocked after starting, so an approval that arrives in the background while the device is locked still finds them. A file that exists but cannot be read is never written over: changes stay in memory and are merged in once a read succeeds. Records are kept across logout, because an Ask to Buy approved while the buyer is signed out arrives after they sign back in.
- Verify responses decode `transferredFromAnotherAccount` (absent means false). Read it from `PurchaseResult.success(entitlements)` or `RestoreResult.transferredCount` to tell the user. It is delivered once, with the result that carried it: it is not cached, not kept in `entitlements`, and not replayed to new stream subscribers.
- Deliberate change: automatic recovery now reports transactions without an app account token (offer codes redeemed in the App Store, promoted purchases, family-shared copies) with claim `sync`, and finishes them once the server credits them. `sync` never moves a purchase another account owns, so such a transaction is left unfinished, as before. One that nobody owns yet goes to whichever account is signed in on the device. That is how an unowned purchase was already attributed on a manual Restore; it now happens without the tap.
- Promoted In-App Purchases (`PurchaseIntent`, iOS 16.4+) run through `purchase(_:)` once a user is identified, one at a time. One that meets another purchase or restore in progress waits for it to end. One that fails before the App Store sheet runs again later: after an offline lookup or a missing product it waits (10 s doubling, half of it random), and after a session that cannot buy (a token under a minute and no working provider) it waits for the next identify. Each gets five attempts within a day. A failed one goes back in the queue with its wait before the next one starts, so failures cannot chase each other round the queue. One that fails after the sheet is never run again, since a charge is possible.
- New `isEligibleForIntroOffer(_:)` asks StoreKit whether this Apple ID can still get a product's introductory offer. The built-in paywall shows an intro offer line, such as "Free for 1 week, then $9.99 / month", only when it can.
- 161 host tests (72 before) and a generic iOS Simulator build. No device or Sandbox acceptance is claimed.

## 1.2.0-rc.1 (2026-09-19): Midgame acceptance candidate (all of it is in 2.0.0)

- Add throwing identity readiness and logout barriers, frozen request identity per operation, and token-refresh API. Cold launches await host authentication.
- Reject missing, expired or mismatched tokens before StoreKit opens.
- Add passive observer mode; purchase, restore, recovery and consumable spending are disabled.
- Publish owner, identity revision, store environment, computation/version metadata and access deadlines. Discard superseded account responses.
- Preserve unfinished transactions on verification failure; expose charged-but-unverified, ownership conflict, verified-without-access and restore verification errors.
- Expose offer metadata and Play base-plan ids on device offerings, with eligibility explicitly unknown.
- Add `PurchaseResult.localStoreKit`; local StoreKit completion no longer implies server access.
- Require the server's per-purchase `purchaseOutcomeConfirmed` result for success. Deploy the matching API before using this candidate.
- Keep published version/install coordinates unchanged. No tag or device acceptance is claimed.
