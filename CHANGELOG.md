# Changelog

## Unreleased — Midgame acceptance candidate, 2026-09-19

- Add throwing identity readiness and logout barriers, frozen request identity per operation, and token-refresh API. Cold launches await host authentication.
- Reject missing, expired or mismatched tokens before StoreKit opens.
- Add passive observer mode; purchase, restore, recovery and consumable spending are disabled.
- Publish owner, identity revision, store environment, computation/version metadata and access deadlines. Discard superseded account responses.
- Preserve unfinished transactions on verification failure; expose charged-but-unverified, ownership conflict, verified-without-access and restore verification errors.
- Expose offer metadata and Play base-plan ids on device offerings, with eligibility explicitly unknown.
- Add `PurchaseResult.localStoreKit`; local StoreKit completion no longer implies server access.
- Require the server's per-purchase `purchaseOutcomeConfirmed` result for success. Deploy the matching API before using this candidate.
- Keep published version/install coordinates unchanged. No tag or device acceptance is claimed.
