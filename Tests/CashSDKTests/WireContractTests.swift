import XCTest
@testable import CashSDK

/// Cross-side wire-contract pins.
///
/// Every response body below was CAPTURED VERBATIM from a real `apps/api` instance booted against
/// the dev Postgres + Redis (`ALLOW_UNVERIFIED_JWS=1`) and driven over HTTP — they are not
/// hand-written approximations of what the server "should" send. Both sides of this contract were
/// rewritten independently, and each suite previously tested only its own assumption of it; these
/// assertions fail if the server's shape and this SDK's parser drift apart again.
///
/// Companion on the server side: `apps/api/test/sdk-wire-contract.test.ts`.
final class WireContractTests: XCTestCase {

    private func decode(_ json: String) throws -> (Data, Entitlements) {
        let data = Data(json.utf8)
        return (data, try JSONDecoder().decode(Entitlements.self, from: data))
    }

    // MARK: - Captured bodies: POST /v1/transactions:verify

    /// Could not map the transaction to a user. Note there is NO `consumables` key.
    private let unattributed = #"""
    {"entitlements":[],"tier":0,"tierIdentifier":null,"attributed":false,"belongsToAnotherAccount":false}
    """#

    /// Credited. A subscription plus a consumable balance carrying expiry fields we don't model.
    private let attributed = #"""
    {"entitlements":[{"identifier":"pro","name":"Pro","rank":3,"source":"subscription"}],
     "tier":3,"tierIdentifier":"pro","consumables":[{"productIdentifier":"com.test.ctr.coins100",
     "balance":2,"validityDays":null,"expiresAt":null,"expiringUnits":null}],
     "attributed":true,"belongsToAnotherAccount":false}
    """#

    /// Real receipt registered to a DIFFERENT app user (restorePolicy = keep_with_original).
    private let belongsToAnother = #"""
    {"entitlements":[],"tier":0,"tierIdentifier":null,"consumables":[],
     "attributed":true,"belongsToAnotherAccount":true}
    """#

    /// The same receipt under restorePolicy = "share": the claimant DOES hold the entitlement.
    private let sharedWithClaimant = #"""
    {"entitlements":[{"identifier":"pro","name":"Pro","rank":3,"source":"subscription"}],
     "tier":3,"tierIdentifier":"pro","consumables":[],
     "attributed":true,"belongsToAnotherAccount":false}
    """#

    /// GET /v1/entitlements — no transaction-scoped fields at all.
    private let entitlementsRead = #"""
    {"entitlements":[{"identifier":"pro","name":"Pro","rank":3,"source":"subscription"}],
     "tier":3,"tierIdentifier":"pro","consumables":[{"productIdentifier":"com.test.ctr.coins100",
     "balance":2,"validityDays":null,"expiresAt":null,"expiringUnits":null}]}
    """#

    // MARK: - 1. `attributed` is explicit on every branch

    func testEveryVerifyBranchCarriesAnExplicitAttributedFlag() throws {
        for body in [unattributed, attributed, belongsToAnother, sharedWithClaimant] {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            )
            XCTAssertNotNil(
                object["attributed"] as? Bool,
                """
                the server must send an explicit `attributed` on EVERY branch — the SDK must never \
                have to guess from response shape, because that guess is what let a paid purchase \
                be finished and credited to nobody: \(body)
                """
            )
        }
    }

    func testUnattributedBranchIsRefused() throws {
        let (data, decoded) = try decode(unattributed)
        XCTAssertFalse(
            APIClient.isAttributed(data, decoded: decoded),
            "finishing here destroys a consumable the user paid for"
        )
    }

    func testAttributedBranchIsAccepted() throws {
        let (data, decoded) = try decode(attributed)
        XCTAssertTrue(APIClient.isAttributed(data, decoded: decoded))
        XCTAssertTrue(decoded.isActive("pro"))
        XCTAssertEqual(decoded.balance(of: "com.test.ctr.coins100"), 2)
    }

    func testExplicitFlagBeatsTheShapeHeuristic() throws {
        // `belongsToAnotherAccount` is attributed but has an EMPTY entitlement list AND an empty
        // `consumables` array — shape alone cannot tell it from the unattributed body. Refusing it
        // would strand a legitimate restore; the explicit flag is what gets this right.
        let (data, decoded) = try decode(belongsToAnother)
        XCTAssertTrue(APIClient.isAttributed(data, decoded: decoded))
    }

    // MARK: - 2. belongsToAnotherAccount / share semantics

    func testBelongsToAnotherAccountIsSurfacedButIsNotAnError() throws {
        let (data, decoded) = try decode(belongsToAnother)
        // Reachable by the host: the server added this field precisely so the SDK could explain
        // the blank ("already used on another Apple ID") instead of showing nothing.
        XCTAssertEqual(decoded.belongsToAnotherAccount, true)
        // …and it is NOT a failure. The transaction was accepted and attributed to the caller.
        XCTAssertTrue(APIClient.isAttributed(data, decoded: decoded))
    }

    func testSharedWithClaimantDoesNotReadAsAnError() throws {
        // Under restorePolicy = "share" the server deliberately clears the flag: the claimant
        // rides the owner's receipt, and reporting "belongs to somebody else" in the very response
        // that grants the entitlement would make family sharing look broken.
        let (_, decoded) = try decode(sharedWithClaimant)
        XCTAssertNotEqual(decoded.belongsToAnotherAccount, true)
        XCTAssertTrue(decoded.isActive("pro"), "the sharing claimant genuinely holds the entitlement")
    }

    func testBelongsToAnotherAccountIsStrippedBeforeCaching() throws {
        let (_, decoded) = try decode(belongsToAnother)
        XCTAssertEqual(decoded.belongsToAnotherAccount, true)
        XCTAssertNil(
            decoded.gatingSnapshot().belongsToAnotherAccount,
            """
            persisting it would rehydrate the conflict on every later launch, so the app would \
            claim 'already used on another Apple ID' forever
            """
        )
    }

    // MARK: - 3. Additive server fields must never break decoding

    func testUnmodelledFieldsAreIgnored() throws {
        // The server ships validityDays/expiresAt/expiringUnits on each balance, and
        // productType/quantity/acknowledged/environment on the Play path. An older SDK must keep
        // working when the server adds fields (FR-6.7 graceful degrade).
        let (_, decoded) = try decode(#"""
        {"entitlements":[],"tier":0,"tierIdentifier":null,"consumables":[],"attributed":true,
         "belongsToAnotherAccount":false,"productType":"consumable","quantity":4,
         "acknowledged":true,"environment":"Sandbox","somethingAddedLater":{"a":1}}
        """#)
        XCTAssertEqual(decoded.tier, 0)
        XCTAssertTrue(decoded.balances.isEmpty)
    }

    func testSnapshotCachedBeforeThisFieldExistedStillDecodes() throws {
        // A record persisted by an older build has no `belongsToAnotherAccount` key at all.
        // Optional (not `Bool`) is what keeps Swift's synthesized Decodable from throwing here —
        // and a throw would mean a paying user hydrates EMPTY on upgrade.
        let (_, decoded) = try decode(#"""
        {"entitlements":[{"identifier":"pro","name":"Pro","rank":3,"source":"subscription"}],
         "tier":3,"tierIdentifier":"pro","consumables":[]}
        """#)
        XCTAssertTrue(decoded.isActive("pro"))
        XCTAssertNil(decoded.belongsToAnotherAccount)
    }

    func testEntitlementsReadCarriesNoTransactionScopedFields() throws {
        let (_, decoded) = try decode(entitlementsRead)
        XCTAssertNil(decoded.belongsToAnotherAccount)
        XCTAssertTrue(decoded.isActive("pro"))
        XCTAssertEqual(decoded.tierIdentifier, "pro")
        XCTAssertEqual(decoded.balance(of: "com.test.ctr.coins100"), 2)
    }

    // MARK: - 4. POST /v1/events request shape

    func testEventBatchMatchesWhatTheServerIngests() throws {
        let payload = EventPayload(
            id: "evt-1",
            event: "paywall_open",
            userId: "user_1",
            placement: "onboarding_finished",
            paywall: "pw_1",
            variant: "var_b",
            product: "sku",
            environment: "Sandbox",
            props: ["k": .string("v")],
            ts: 1_700_000_000_000
        )
        let data = try JSONEncoder().encode(EventBatch(events: [payload], platform: "ios", appVersion: "1.2.3"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["platform"] as? String, "ios")
        XCTAssertNotNil(object["appVersion"], "the server reads batch.appVersion")
        let event = try XCTUnwrap((object["events"] as? [[String: Any]])?.first)

        // The server dedupes on `[appId, clientEventId]`, reading it from `id`. Renaming or
        // dropping this makes every retry of a durable batch double-count.
        XCTAssertEqual(event["id"] as? String, "evt-1")
        // `variant` is a first-class column server-side (Event.variant) — the only field
        // experiment reporting reads. It must not be buried inside `props`.
        XCTAssertEqual(event["variant"] as? String, "var_b")
        // Stamped at RECORD time: the queue is durable, so letting the server date the row at
        // ingest re-times every event recorded offline.
        XCTAssertEqual(event["ts"] as? Double, 1_700_000_000_000)
    }

    // MARK: - 5. GET /v1/paywalls:resolve

    /// Captured verbatim from a live resolve with a matching campaign + offering. `offering` is
    /// the part that bites: it is `Optional` on the response, which tolerates ABSENCE but not a
    /// shape mismatch — a renamed key inside it throws, and `register()` swallows the throw as
    /// `.resolverError`, silently showing no paywall at all.
    /// `schema_version: 2` — the component-tree shape `apps/api/src/paywalls/config-schema.ts`
    /// calls "the source of truth", and what every seed template and the AI builder emit.
    private let resolveBody = #"""
    {"paywall":{"id":"pw_1","identifier":"m","config":{
     "schema_version":2,"presentation":"fullscreen","feature_gating":"non_gated",
     "theme":{"accent":"#6366F1","background":"#FFFFFF","text":"#111827","corner_radius":16,"dark_mode":"auto"},
     "products":[{"role":"primary","product_id":"com.dr.pro.yearly"},
                 {"role":"secondary","product_id":"com.dr.pro.monthly"}],
     "root":{"type":"stack","children":[
       {"type":"text","role":"title","text":"Unlock everything","style":{"size":28,"weight":"bold"}},
       {"type":"feature_list","items":[{"icon":"check","text":"Unlimited access"}]},
       {"type":"product_selector","layout":"vertical_cards","default":"primary"},
       {"type":"button","text":"Continue","action":"purchase_selected"}]}}},
     "offering":{"id":"off_1","identifier":"default","displayName":"Default","isCurrent":true,
     "packages":[{"id":"pkg_1","identifier":"$monthly","position":0,
     "product":{"id":"prod_1","identifier":"com.dr.pro.monthly","basePlanId":null,"store":"app-store",
     "type":"auto_renewable","duration":"P1M","price":9990,"currency":"USD","displayName":"Pro Monthly"}}]},
     "offers":[],"trialEligibility":[{"productId":"prod_1","productIdentifier":"com.dr.pro.monthly",
     "eligible":true,"mode":"auto","reason":"no_prior_purchase"}],
     "variantId":"var_1","experimentId":"camp_1"}
    """#

    func testRealResolveBodyDecodes() throws {
        let decoded = try JSONDecoder().decode(PaywallResolveResponse.self, from: Data(resolveBody.utf8))
        let config = try XCTUnwrap(decoded.paywall?.config, "no config means register() shows nothing")
        XCTAssertEqual(decoded.variantId, "var_1")
        XCTAssertEqual(decoded.experimentId, "camp_1")
        // Server config keys are snake_case; the model maps them explicitly.
        XCTAssertEqual(config.schemaVersion, 2)
        XCTAssertEqual(config.featureGating, "non_gated")
        XCTAssertFalse(config.prefersSheet)
        XCTAssertEqual(config.theme?.accent, "#6366F1")
        XCTAssertEqual(config.theme?.cornerRadius, 16)
        XCTAssertEqual(config.products?.first?.productId, "com.dr.pro.yearly")
        // The component tree is the part the renderer walks — an SDK that decoded everything
        // EXCEPT `root` would draw a blank paywall without ever erroring.
        XCTAssertNotNil(config.root, "the v2 component tree must decode — it IS the paywall")
        // …and the offering rides along so product ids are never hardcoded in the host app.
        XCTAssertEqual(decoded.offering?.monthly?.product.identifier, "com.dr.pro.monthly")
        XCTAssertEqual(decoded.offering?.monthly?.product.price, 9990)
        XCTAssertNil(decoded.holdout)
    }

    func testResolveSkipShapesDecode() throws {
        // No campaign matched, and the holdout arm. Both must decode rather than throw — a throw
        // is reported as `.resolverError`, which is indistinguishable from a real outage.
        let noPaywall = #"{"paywall":null,"offers":[],"trialEligibility":[]}"#
        XCTAssertNil(try JSONDecoder().decode(PaywallResolveResponse.self, from: Data(noPaywall.utf8)).paywall)
        let holdout = #"{"paywall":null,"offers":[],"trialEligibility":[],"holdout":true,"experimentId":"camp_1"}"#
        let decoded = try JSONDecoder().decode(PaywallResolveResponse.self, from: Data(holdout.utf8))
        XCTAssertEqual(decoded.holdout, true)
    }

    func testResolveMustNotBeTheOfflineFallbackBundle() throws {
        // `@Get("paywalls:fallback")` compiles to "paywalls" + a route PARAMETER, so it once
        // matched /v1/paywalls<anything> and swallowed this endpoint. The bundle decodes into an
        // all-nil response, so the failure was completely silent: every register() advanced as
        // "no paywall". If this ever regresses, the assertions above are what catch it.
        let bundle = #"{"generatedAt":"2026-07-29T19:39:26.171Z","note":"Offline fallback snapshot","placements":[]}"#
        let decoded = try JSONDecoder().decode(PaywallResolveResponse.self, from: Data(bundle.utf8))
        XCTAssertNil(decoded.paywall, "the fallback bundle is NOT a resolve response")
        XCTAssertNil(decoded.variantId)
    }

    // MARK: - 6. appAccountToken parity (golden vectors — DO NOT change the derivation)

    func testAppAccountTokenMatchesTheServerGoldenVectors() {
        // Produced by `deriveAppAccountToken` in apps/api/src/common/app-account-token.ts.
        // Byte-parity across server / iOS / Android is what makes async store notifications
        // attributable at all; these are pinned, not to be "fixed".
        let golden = [
            "1": "00000000-0000-4000-8000-000000000001",
            "42": "00000000-0000-4000-8000-00000000002a",
            "281474976710655": "00000000-0000-4000-8000-ffffffffffff",
        ]
        for (userId, expected) in golden {
            XCTAssertEqual(
                AppAccountToken.appAccountToken(for: userId)?.uuidString.lowercased(),
                expected,
                "numeric ids embed their VALUE, so the token stays reversible"
            )
        }
        // Zero-padding collapses on the numeric branch — identically on all three sides.
        XCTAssertEqual(AppAccountToken.hex12("7"), AppAccountToken.hex12("007"))
        // Out-of-range / non-digit ids take the FNV branch: stable and byte-sensitive.
        for id in ["0", "281474976710656", "+15551234567", "user_abc"] {
            let hex = AppAccountToken.hex12(id)
            XCTAssertEqual(hex.count, 12, "\(id) -> \(hex)")
            XCTAssertEqual(hex, AppAccountToken.hex12(id), "stable across calls")
        }
    }
}
