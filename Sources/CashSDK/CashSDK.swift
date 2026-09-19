import Foundation
import StoreKit

/// Receives entitlement updates as an alternative to ``CashSDK/entitlementUpdates``.
/// Called on the main actor.
public protocol CashSDKDelegate: AnyObject {
    func cashSDK(_ sdk: CashSDK, didUpdateEntitlements entitlements: Entitlements)
}

/// The CashSDK facade.
///
/// ```swift
/// CashSDK.configure(publishableKey: "csk_pk_…")
/// CashSDK.shared.identify(userId: "8841")
/// let result = try await CashSDK.shared.purchase("app.example.pro.yearly")
/// CashSDK.shared.register(placement: "onboarding_finished")
/// ```
///
/// Reads (`entitlements`) never touch the network — they're served from a lock-guarded
/// server snapshot hydrated from disk. Writes (verify reports) flow through the
/// API and refresh the snapshot, which is broadcast on ``entitlementUpdates`` and to the
/// ``delegate``.
public final class CashSDK: @unchecked Sendable {
    /// The shared instance. Use after calling ``configure(publishableKey:apiBase:)``.
    public static let shared = CashSDK()

    // Subsystems
    private let store = EntitlementStore()
    private let identityStore = IdentityStore()
    // `internal` (not `private`): the paywall resolver lives in `CashSDK+Paywalls.swift`, and a
    // Swift extension in a separate file can't see `private` members.
    let storeKit = StoreKitManager()

    /// Every identity mutation (bootstrap, identify, logout) runs here, in call order. Bare
    /// `Task`s are unordered, so `logout(); identify("B")` could previously land backwards and
    /// null the API client's identity while `currentUserId == "B"` — every subsequent verify
    /// went out unattributed and every entitlements read 401'd until the next identify.
    let identityQueue = SerialTaskQueue()

    /// Snapshot persistence, also strictly ordered: two unordered writes can land newest-first
    /// and leave a stale entitlement cache on disk.
    private let persistQueue = SerialTaskQueue()

    /// The unfinished-transaction drain. Its own queue so (a) two drains never run concurrently
    /// and re-report the same JWS, and (b) a slow drain never delays an `identify()` behind it.
    private let backstopQueue = SerialTaskQueue()

    /// Durable, bounded event queue. `internal` (not `private`): the event pipeline lives in
    /// `CashSDK+Events.swift`, and a Swift extension in another file can't see `private`.
    let eventQueue = EventQueue()

    /// Event WRITES, in call order — an event must reach disk in the order it was recorded.
    let eventWriteQueue = SerialTaskQueue()

    /// Event FLUSHES, serialized so two triggers (a threshold hit and a foreground, say) can
    /// never put the same batch on the wire twice.
    let eventFlushQueue = SerialTaskQueue()

    // Lock-guarded state (readable from any thread/actor)
    private let configuration = Locked<CashSDKConfiguration?>(nil)
    private let client = Locked<APIClient?>(nil)
    private let snapshot = Locked<Entitlements>(.empty)
    // `internal` (not `private`): read by the event pipeline in `CashSDK+Events.swift`.
    let currentUserId = Locked<String?>(nil)
    private let continuations = Locked<[UUID: AsyncStream<Entitlements>.Continuation]>([:])
    // `internal` (not `private`): the flush scheduler lives in `CashSDK+Events.swift`.
    /// A deferred flush is already pending — coalesces bursts and keeps a retry backoff from
    /// being reset by ordinary traffic.
    let flushScheduled = Locked<Bool>(false)
    /// Consecutive failed flushes; drives the exponential backoff.
    let eventFlushFailures = Locked<Int>(0)
    /// `configure()` is documented as call-once, but a host that calls it twice must not end up
    /// with two foreground observers flushing the same queue twice.
    let foregroundObserverInstalled = Locked<Bool>(false)

    /// Bumped by every identity mutation. A queued block whose generation is stale has been
    /// superseded by a later call and must not touch the API client's identity.
    private let identityGeneration = Locked<UInt64>(0)
    private let purchaseOperationGate = PurchaseOperationGate()
    private let readyIdentity = Locked<ReadyIdentity?>(nil)
    private let identityError = Locked<Error?>(nil)

    /// The store environment learned from StoreKit or the server, used when none was configured.
    private let observedEnvironment = Locked<String?>(nil)

    /// Where `observedEnvironment` survives a relaunch. `internal` so tests can reset it.
    ///
    /// It has to survive: consumables are excluded from StoreKit's `currentEntitlements`, so a
    /// tester whose only purchases are coin packs re-reports nothing on the next launch and the
    /// SDK would forget it is in Sandbox. Balances are per environment server-side, so that
    /// forgetting reads back as "my coins are gone". The environment of an install never
    /// changes (a TestFlight install stays TestFlight), so remembering it is always right.
    static let observedEnvironmentKey = "com.cashsdk.observedEnvironment"

    /// Bounded in-session retries of the unfinished-transaction drain.
    private let backstopRetries = Locked<Int>(0)

    /// Delegate for entitlement updates. Set/read on the main actor.
    public weak var delegate: CashSDKDelegate?

    private let urlSession: URLSession
    private let automaticRecovery: Bool
    init(session: URLSession = .shared, automaticRecovery: Bool = true) {
        urlSession = session
        self.automaticRecovery = automaticRecovery
    }

    // MARK: - Configuration

    /// Configure the SDK. Call once, early in app launch.
    ///
    /// - Parameters:
    ///   - publishableKey: The app's `csk_pk_…` key.
    ///   - apiBase: Override the REST base URL (defaults to `https://api.cashsdk.com`).
    ///   - environment: Pin the store environment (`"Sandbox"` / `"Production"`). Leave `nil`
    ///     to learn it from the first verified StoreKit transaction.
    public static func configure(publishableKey: String, apiBase: URL? = nil, environment: String? = nil, observerMode: Bool = false) {
        let configuration = CashSDKConfiguration(
            publishableKey: publishableKey,
            apiBase: apiBase ?? CashSDKConfiguration.defaultAPIBase,
            environment: environment,
            observerMode: observerMode
        )
        shared.configure(with: configuration)
    }

    func configure(with configuration: CashSDKConfiguration) {
        let client = APIClient(configuration: configuration, session: self.urlSession)
        identityGeneration.withValue { generation in
            generation &+= 1
            self.configuration.value = configuration
            self.client.value = client
            readyIdentity.value = nil
            identityError.value = nil
            currentUserId.value = nil
            snapshot.value = .empty
        }
        storeKit.stopListening()
        // Restore the environment a previous run learned, unless the host pinned one. Done
        // synchronously here so the very first request of this run already carries it. A
        // re-configure re-derives from disk rather than inheriting the previous client's
        // in-memory value, so `configure()` always means the same thing.
        let remembered = configuration.environment == nil
            ? UserDefaults.standard.string(forKey: Self.observedEnvironmentKey)
                .flatMap { $0 == "Sandbox" || $0 == "Production" ? $0 : nil }
            : nil
        observedEnvironment.value = remembered
        if let remembered {
            Task { await client.setEnvironment(remembered) }
        }
        // Drain whatever a previous run left on disk (offline, backgrounded, killed) and keep
        // draining every time the app comes back to the foreground.
        observeForegroundForEventFlush()
        flushEvents()
        // On the identity queue so a synchronous `configure(); identify(…)` can never hydrate
        // the cache AFTER the identify that was supposed to switch it.
        identityQueue.enqueue { [weak self] in await self?.bootstrap() }
    }

    /// Restore identity, hydrate the cached snapshot, start the StoreKit updates listener, and
    /// drain anything StoreKit is redelivering from a previous run.
    private func bootstrap() async {
        // Hosts establish a fresh session on every launch. A persisted token is never proof
        // that the app has finished authenticating the current person.
        guard automaticRecovery, configuration.value?.observerMode != true else { return }
        storeKit.startListening { [weak self] verification in
            await self?.handleTransactionUpdate(verification)
        }
    }

    /// Queue a drain of unfinished transactions. Fire-and-forget on purpose: reporting every
    /// stranded purchase can take several round trips, and nothing else should wait for it.
    private func enqueueBackstop() {
        backstopQueue.enqueue { [weak self] in
            guard let self, self.currentUserId.value != nil else { return }
            await self.launchBackstop()
        }
    }

    /// Load the on-disk snapshot that belongs to `userId` (and this environment) and adopt its
    /// ETag. A cache owned by anyone else yields `.empty` — never another user's entitlements.
    private func hydrateSnapshot(for identity: ReadyIdentity) async {
        let cached = await store.load(for: identity.userId, environment: await effectiveEnvironment())
        guard identityGeneration.value == identity.revision else { return }
        await identity.api.setEntitlementsETag(cached.etag)
        applySnapshot(cached.entitlements, persist: false, expectedGeneration: identity.revision)
    }

    // MARK: - Identity

    /// Associate subsequent calls with a user. Sends `X-CashSDK-User-Id` on device
    /// requests and derives the deterministic `appAccountToken` for purchases.
    ///
    /// - Parameter userToken: the signed user token (`X-CashSDK-User-Token`) minted by YOUR
    ///   backend (HS256 over the per-app secret; never on the client). Production trusts only
    ///   this — without it, identified verify/entitlement/consumable calls are rejected live.
    ///   Omit it only for local/dev, where the server accepts the raw id.
    ///
    /// Call this on EVERY launch with a freshly minted `userToken`. Recovery waits until
    /// the host authenticates the user; a persisted identity is never installed automatically.
    public func identify(userId: String, userToken: String? = nil) {
        _ = queueIdentity(userId: userId, userToken: userToken)
    }

    private func queueIdentity(userId: String, userToken: String?) -> UInt64 {
        let generation = identityGeneration.withValue { generation -> UInt64 in
            generation &+= 1
            readyIdentity.value = nil
            identityError.value = nil
            currentUserId.value = userId
            snapshot.value = .empty
            identityStore.save(userId: userId, userToken: userToken)
            broadcast(.empty, expectedGeneration: generation)
            return generation
        }
        installIdentity(userId: userId, userToken: userToken, generation: generation)
        return generation
    }

    private func installIdentity(userId: String, userToken: String?, generation: UInt64) {
        identityQueue.enqueue { [weak self] in
            guard let self, self.identityGeneration.value == generation else { return }
            do {
                guard let configuration = self.configuration.value else { throw CashSDKError.notConfigured }
                try self.validateToken(userToken, userId: userId)
                // A new client per identity: an in-flight payment keeps its original headers
                // even when a later login replaces the client's public reference.
                let api = APIClient(configuration: configuration, session: self.urlSession)
                await api.setIdentity(userId: userId, userToken: userToken)
                await api.setEnvironment(self.effectiveStoreEnvironment)
                let identity = ReadyIdentity(userId: userId, token: userToken, revision: generation, api: api)
                await self.hydrateSnapshot(for: identity)
                self.identityGeneration.withValue { current in
                    guard current == generation else { return }
                    self.client.value = api
                    self.readyIdentity.value = identity
                }
                guard self.identityGeneration.value == generation else { return }
                self.recordEvent("identify")
                self.reconcileOnForeground()
            } catch {
                self.identityGeneration.withValue { current in
                    guard current == generation else { return }
                    self.readyIdentity.value = nil
                    self.identityError.value = error
                }
            }
        }
    }

    /// Completes only when the same user/token pair is installed for purchases, restore,
    /// cache ownership and background recovery. Superseded calls throw.
    @discardableResult
    public func identifyAndWait(userId: String, userToken: String) async throws -> IdentityReadiness {
        let revision = queueIdentity(userId: userId, userToken: userToken)
        return try await waitUntilReady(expectedRevision: revision)
    }

    @discardableResult
    public func waitUntilReady(expectedRevision: UInt64? = nil) async throws -> IdentityReadiness {
        let generation = expectedRevision ?? identityGeneration.value
        await identityQueue.drain()
        try Task.checkCancellation()
        guard identityGeneration.value == generation else { throw CashSDKError.identityChanged }
        let identity = try captureReadyIdentity()
        guard identity.revision == generation else { throw CashSDKError.identityChanged }
        return IdentityReadiness(userId: identity.userId, revision: identity.revision)
    }

    private func validateToken(_ token: String?, userId: String) throws {
        let host = configuration.value?.apiBase.host ?? ""
        try validateIdentityToken(token, userId: userId,
            allowUnsignedLocalIdentity: ["localhost", "127.0.0.1", "::1"].contains(host))
    }

    private func captureReadyIdentity() throws -> ReadyIdentity {
        try identityGeneration.withValue { generation in
            guard configuration.value != nil else { throw CashSDKError.notConfigured }
            if let error = identityError.value { throw error }
            guard let identity = readyIdentity.value, identity.revision == generation else {
                throw CashSDKError.notIdentified
            }
            try validateToken(identity.token, userId: identity.userId)
            return identity
        }
    }

    /// Calls the host's token issuer. Readiness is revoked before refresh starts; a failed
    /// refresh or a late response can never restore a superseded identity.
    @discardableResult
    public func refreshUserToken(using refresh: @Sendable (String) async throws -> String) async throws -> IdentityReadiness {
        let (owner, generation) = try identityGeneration.withValue { generation -> (String, UInt64) in
            guard let owner = currentUserId.value else { throw CashSDKError.notIdentified }
            generation &+= 1
            readyIdentity.value = nil
            identityError.value = nil
            return (owner, generation)
        }
        do {
            let token = try await refresh(owner)
            try Task.checkCancellation()
            guard identityGeneration.value == generation else { throw CashSDKError.identityChanged }
            try validateToken(token, userId: owner)
            identityGeneration.withValue { current in
                if current == generation { identityStore.save(userId: owner, userToken: token) }
            }
            installIdentity(userId: owner, userToken: token, generation: generation)
            let result = try await waitUntilReady()
            guard result.revision == generation else { throw CashSDKError.identityChanged }
            return result
        } catch {
            identityGeneration.withValue { current in
                if current == generation { readyIdentity.value = nil; identityError.value = error }
            }
            throw error
        }
    }

    /// Immediately clears access; queued cache removal completes at logoutAndWait().
    public func logout() { _ = queueLogout() }

    private func queueLogout() -> UInt64 {
        let generation = identityGeneration.withValue { generation -> UInt64 in
            generation &+= 1
            readyIdentity.value = nil
            identityError.value = nil
            currentUserId.value = nil
            snapshot.value = .empty
            identityStore.clear()
            broadcast(.empty, expectedGeneration: generation)
            return generation
        }
        identityQueue.enqueue { [weak self] in
            guard let self, self.identityGeneration.value == generation else { return }
            await self.persistQueue.drain()
            await self.store.clear()
            guard self.identityGeneration.value == generation else { return }
            if let configuration = self.configuration.value { self.client.value = APIClient(configuration: configuration, session: self.urlSession) }
            self.recordEvent("logout")
        }
        return generation
    }

    public func logoutAndWait() async throws {
        let generation = queueLogout()
        await identityQueue.drain()
        try Task.checkCancellation()
        guard identityGeneration.value == generation, currentUserId.value == nil else { throw CashSDKError.identityChanged }
    }

    func reconcileOnForeground() {
        guard automaticRecovery else { return }
        Task { [weak self] in
            guard let self, (try? await self.waitUntilReady()) != nil else { return }
            if self.configuration.value?.observerMode != true { self.enqueueBackstop() }
            _ = try? await self.refreshEntitlements()
        }
    }

    // MARK: - Entitlements

    /// The current cached entitlement snapshot. Synchronous and offline-valid.
    public var entitlements: Entitlements { identityGeneration.withValue { _ in snapshot.value.removingExpiredAccess() } }

    /// The numeric tier (rank of the highest active entitlement; `0` when none).
    public var tier: Int { entitlements.tier }

    /// The identifier of the highest active entitlement, or `nil`.
    public var tierIdentifier: String? { entitlements.tierIdentifier }

    /// A stream of entitlement snapshots. Each new subscriber immediately receives the
    /// current value, then every subsequent update.
    public var entitlementUpdates: AsyncStream<Entitlements> {
        AsyncStream { continuation in
            let id = UUID()
            identityGeneration.withValue { _ in
                continuation.yield(snapshot.value.removingExpiredAccess())
                continuations.withValue { $0[id] = continuation }
            }
            continuation.onTermination = { [weak self] _ in
                self?.continuations.withValue { $0[id] = nil }
            }
        }
    }

    // MARK: - Purchase

    /// Purchase a product by its StoreKit identifier. Verifies with the server and
    /// returns the fresh snapshot on success.
    @discardableResult
    public func purchase(_ productId: String) async throws -> PurchaseResult {
        try purchaseOperationGate.begin()
        defer { purchaseOperationGate.end() }
        guard configuration.value?.observerMode != true else { throw CashSDKError.observerMode }
        _ = try await waitUntilReady()
        let identity = try captureReadyIdentity()
        // A purchase before identify() has no user to attribute to: appAccountToken() is nil, so
        // StoreKit stamps no token, the server credits nobody (200 + empty entitlements),
        // verifyAndApply does NOT throw, and finish() then permanently discards the transaction —
        // a consumable paid for and lost (it's gone from currentEntitlements, so the launch
        // backstop can't recover it either). Require an identified user up front so we never
        // charge for something we cannot attribute.
        let buyer = identity.userId
        let generation = identity.revision
        let products = try await storeKit.products(for: [productId])
        guard let product = products.first else { throw CashSDKError.productNotFound(productId) }
        guard identityGeneration.value == generation else { throw CashSDKError.identityChanged }
        try validateToken(identity.token, userId: buyer)
        try Task.checkCancellation()

        recordEvent("purchase_start", product: productId)
        let outcome = try await storeKit.purchase(product, appAccountToken: AppAccountToken.appAccountToken(for: buyer))

        switch outcome {
        case .userCancelled:
            recordEvent("purchase_cancel", product: productId)
            return .userCancelled
        case .pending:
            recordEvent("purchase_pending", product: productId)
            return .pending
        case .verified(let transaction, let jws):
            if shouldVerify(transaction) {
                await noteEnvironment(transaction, using: identity.api, expectedGeneration: identity.revision)
                // Verify + record with the server BEFORE finishing. finish() removes the
                // transaction from the payment queue (and from currentEntitlements for a
                // consumable), so finishing first meant a network failure here lost the
                // purchase server-side while StoreKit considered it done — a consumable could
                // never be recovered by the launch backstop. If verifyAndApply throws, we
                // leave it UNFINISHED so Transaction.updates redelivers it and we retry.
                let entitlements: Entitlements?
                do {
                    entitlements = try await verifyAndApply(jws, identity: identity)
                } catch {
                    // Deliberately NOT finished. Schedule a bounded in-session retry so a
                    // transient failure doesn't have to wait for the next launch or a manual
                    // restore() to be recovered.
                    recordEvent("purchase_verify_failed", product: productId)
                    scheduleVerifyRetry()
                    if case CashSDKError.purchaseBelongsToAnotherAccount = error { throw error }
                    throw CashSDKError.chargedButUnverified(transactionId: String(transaction.id), underlying: error)
                }
                await transaction.finish()
                guard entitlements?.purchaseOutcomeConfirmed == true else {
                    throw CashSDKError.verifiedWithoutAccess(transactionId: String(transaction.id))
                }
                recordEvent("purchase_success", product: productId)
                return .success(entitlements ?? snapshot.value)
            }
            // Xcode / local StoreKit environment: server sync is disabled by design, so there is
            // nothing to lose by finishing now — do it so StoreKit doesn't redeliver.
            //
            // Say so. This is the first thing most developers try (StoreKit Testing in the
            // simulator needs no sandbox account and no device), and until this message existed
            // it returned `.success` with unchanged entitlements and an empty dashboard,
            // explaining nothing. The integration looked broken when it was working correctly.
            CashSDKLog.once(
                "xcode-environment",
                """
                Purchase completed in Xcode's LOCAL StoreKit environment (a .storekit \
                configuration file). Apple does not sign these transactions, so there is nothing \
                CashSDK can verify: this purchase was NOT sent to the server, will NOT appear in \
                your dashboard, and does NOT grant a server-side entitlement. Local StoreKit \
                entitlements still drive your UI, so paywall and offering code can be built this \
                way. To exercise the full path (verification, webhooks, entitlements, revenue) \
                run on a real device signed into a Sandbox Apple ID. See \
                https://docs.cashsdk.com/sdk/ios#testing
                """
            )
            await transaction.finish()
            recordEvent("purchase_success", product: productId)
            return .localStoreKit
        }
    }

    /// Restore purchases: sync with the App Store, report current entitlements, and
    /// re-resolve the server snapshot.
    public func restore() async throws {
        try purchaseOperationGate.begin()
        defer { purchaseOperationGate.end() }
        guard configuration.value?.observerMode != true else { throw CashSDKError.observerMode }
        _ = try await waitUntilReady()
        let identity = try captureReadyIdentity()
        let generation = identity.revision
        recordEvent("restore_start")
        do { try await storeKit.sync() }
        catch { throw CashSDKError.restoreVerificationFailed(underlying: error) }
        try Task.checkCancellation()
        guard identityGeneration.value == generation else { throw CashSDKError.notIdentified }
        // Through the backstop queue (and awaited) so this never races a launch/identify drain
        // that is already re-reporting the same transactions.
        let failure = Locked<Error?>(nil)
        backstopQueue.enqueue { [weak self] in
            await self?.launchBackstop(explicitRestore: true, expectedGeneration: generation) { error in
                failure.withValue { if $0 == nil { $0 = error } }
            }
        }
        await backstopQueue.drain()
        try Task.checkCancellation()
        guard identityGeneration.value == generation else { throw CashSDKError.notIdentified }
        if let error = failure.value { throw CashSDKError.restoreVerificationFailed(underlying: error) }
        _ = try await refreshEntitlements()
        guard identityGeneration.value == generation else { throw CashSDKError.notIdentified }
        recordEvent("restore_success")
    }

    // MARK: - Offerings

    /// The offering this app would present right now, expanded to packages and products.
    ///
    /// Returns `nil` when no offering is configured — a normal state before catalog setup,
    /// not an error. Use it to build a custom paywall without hardcoding product identifiers:
    ///
    /// ```swift
    /// if let offering = try await CashSDK.shared.offerings(),
    ///    let annual = offering.annual {
    ///     let result = try await CashSDK.shared.purchase(annual.product.identifier)
    /// }
    /// ```
    ///
    /// Prices here are the CATALOG's, which is what the server last synced from the store.
    /// For the exact localized price to display, read StoreKit's own `Product` — this tells
    /// you *which* products to show and how they are grouped, not what to render as text.
    public func offerings() async throws -> Offering? {
        guard let client = apiClient() else { throw CashSDKError.notConfigured }
        return try await client.currentOffering()
    }

    // MARK: - Paywalls
    //
    // `register` / `getPresentationResult` / `resolveAndPresent` / `skip` live in
    // `CashSDK+Paywalls.swift`.

    // MARK: - Consumables

    /// Spendable balance of a consumable product, from the cached snapshot
    /// (synchronous and offline-valid, like ``entitlements``).
    /// May be NEGATIVE after a refund of units the user already spent.
    public func consumableBalance(_ productIdentifier: String) -> Int {
        entitlements.balance(of: productIdentifier)
    }

    /// Spend units of a consumable (e.g. deduct 10 coins).
    ///
    /// `idempotencyKey` must be STABLE for a given logical spend — reuse the same key
    /// when retrying, or a dropped response will debit the user twice. Use the id of
    /// whatever the spend buys (a level unlock, a generation request), not a fresh UUID
    /// per attempt.
    ///
    /// Throws if the balance is insufficient. Refreshes the cached snapshot on success.
    @discardableResult
    public func spendConsumable(
        _ productIdentifier: String,
        units: Int,
        idempotencyKey: String,
        note: String? = nil
    ) async throws -> ConsumableSpendResult {
        guard configuration.value?.observerMode != true else { throw CashSDKError.observerMode }
        _ = try await waitUntilReady()
        let identity = try captureReadyIdentity()
        let api = identity.api
        let result = try await api.spendConsumable(
            productIdentifier: productIdentifier,
            units: units,
            idempotencyKey: idempotencyKey,
            note: note
        )
        // Reflect the new balance locally without waiting for the next entitlements poll. Drop the
        // ETag first: the spend changed the balance, so this fetch must return a fresh body rather
        // than a 304 against the pre-spend snapshot (which would leave a stale balance on screen).
        await api.clearEntitlementsETag()
        if let refreshed = try? await api.fetchEntitlements() {
            applySnapshot(refreshed, persist: true, etag: await api.entitlementsETag(), expectedGeneration: identity.revision)
        }
        return result
    }

    // MARK: - Events
    //
    // `logEvent` / `recordEvent` / `enqueue` / `scheduleFlush` / `flushEvents` live in
    // `CashSDK+Events.swift`.

    // MARK: - Internal helpers

    // `internal` (not `private`): the paywall + event extensions in their own files resolve the
    // API client through this accessor.
    func apiClient() -> APIClient? { client.value }

    /// Report a verified JWS to `transactions:verify` and apply the returned snapshot.
    ///
    /// Throws ``CashSDKError/purchaseNotAttributed`` when the server answered `200` but credited
    /// the purchase to nobody. That response is a well-formed EMPTY snapshot, and treating it as
    /// success did two unrecoverable things: it persisted the empty snapshot over a good cache,
    /// and it let the caller `finish()` the transaction — a promoted IAP (which arrives with no
    /// `appAccountToken`) was charged, discarded, and credited to no one. Throwing keeps the
    /// transaction unfinished so StoreKit redelivers it after the next `identify(...)`.
    @discardableResult
    private func verifyAndApply(_ jws: String, identity captured: ReadyIdentity? = nil, expectedGeneration: UInt64? = nil) async throws -> Entitlements? {
        let identity = try captured ?? captureReadyIdentity()
        if let expectedGeneration, expectedGeneration != identity.revision { throw CashSDKError.identityChanged }
        let api = identity.api
        let owner = identity.userId
        let generation = identity.revision
        let outcome = try await withRetry {
            try await api.verify(signedTransaction: jws)
        }
        try requirePurchaseAttribution(attributed: outcome.attributed,
                                       belongsToAnotherAccount: outcome.entitlements?.belongsToAnotherAccount)
        if let responseOwner = outcome.entitlements?.userId, responseOwner != owner {
            throw CashSDKError.invalidResponse
        }
        // Connectivity is provably back — drain any telemetry backlog sitting out a backoff.
        networkDidSucceed()
        // Adopt the environment the SERVER resolved this purchase into, before applying the
        // snapshot. `noteEnvironment` already reads it locally from `Transaction.environment`,
        // but that property is iOS 16+: on iOS 15 this response is the only way the device can
        // learn it, and without it the next `GET /v1/entitlements` falls back to the app
        // default and a sandbox tester's purchase reads back empty. Mirrors the Android SDK,
        // where Play Billing never tells the client at all.
        //
        // Header first, body second, including compatibility with older servers.
        // The purchase IS recorded server-side, so this counts as success — but the snapshot
        // describes whoever was signed in when the request went out. Applying it after a user
        // switch would show A's entitlements to B.
        guard identityGeneration.value == generation, currentUserId.value == owner else { return outcome.entitlements?.withIdentity(userId: owner, revision: generation, environment: outcome.environment) }
        await adoptEnvironment(outcome.environment ?? outcome.entitlements?.environment, using: api, expectedGeneration: generation)
        if let entitlements = outcome.entitlements {
            applySnapshot(entitlements, persist: true, etag: outcome.etag, expectedGeneration: generation)
        }
        backstopRetries.value = 0
        return outcome.entitlements?.withIdentity(userId: owner, revision: generation, environment: outcome.environment)
    }

    /// Re-read the server snapshot (`GET /v1/entitlements`). Requires an identified user.
    @discardableResult
    public func refreshEntitlements() async throws -> Entitlements? {
        let identity = try captureReadyIdentity()
        let entitlements = try await identity.api.fetchEntitlements()
        guard identityGeneration.value == identity.revision else { throw CashSDKError.identityChanged }
        networkDidSucceed()
        if let entitlements {
            applySnapshot(entitlements, persist: true, etag: await identity.api.entitlementsETag(), expectedGeneration: identity.revision)
        }
        return entitlements
    }

    /// Retry a transient failure (offline, timeout, `429`, `5xx`) with exponential backoff.
    /// Safe for `transactions:verify`, which the server dedupes by transaction id.
    private func withRetry<T>(attempts: Int = 3, _ operation: () async throws -> T) async throws -> T {
        var delay: UInt64 = 500 * NSEC_PER_MSEC
        for _ in 1..<max(attempts, 1) {
            do {
                return try await operation()
            } catch {
                guard Self.isRetryable(error) else { throw error }
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        return try await operation()
    }

    /// `internal` (not `private`): the event flusher in `CashSDK+Events.swift` uses the same
    /// rule to decide between backing off and dropping a permanently-rejected batch.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case CashSDKError.network:
            return true
        case CashSDKError.server(let status, _, _):
            return status == 408 || status == 429 || status >= 500
        default:
            // 4xx (bad key, unauthenticated user, invalid signature) will not change on retry;
            // `purchaseNotAttributed` needs an identify(), not another attempt.
            return false
        }
    }

    /// Schedule a bounded, backed-off re-drain of unfinished transactions after a failed verify,
    /// so a charged-but-unreported purchase is recovered within the SAME session instead of
    /// waiting for the next launch or a manual `restore()`.
    private func scheduleVerifyRetry() {
        let attempt = backstopRetries.withValue { $0 += 1; return $0 }
        guard attempt <= 3 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 15 * NSEC_PER_SEC)
            guard let self, self.currentUserId.value != nil else { return }
            self.enqueueBackstop()
        }
    }

    /// Handle a transaction from the `Transaction.updates` listener.
    private func handleTransactionUpdate(_ verification: VerificationResult<Transaction>) async {
        guard configuration.value?.observerMode != true,
              (try? await waitUntilReady()) != nil,
              let identity = try? captureReadyIdentity() else { return }
        let generation = identity.revision
        guard case .verified(let transaction) = verification else { return }
        let jws = verification.jwsRepresentation
        guard shouldVerify(transaction) else {
            await transaction.finish() // Xcode env: nothing to sync — finish so it doesn't repeat.
            return
        }
        // Do NOT verify+finish before a user is identified. StoreKit re-delivers unfinished
        // transactions at launch — often BEFORE the app calls identify() — and the server can't
        // attribute an unidentified purchase (it answers 200 + empty, crediting nobody). Finishing
        // here would permanently lose a CONSUMABLE. Leave it unfinished; launchBackstop (invoked on
        // identify) drains Transaction.unfinished once a user is known.
        guard currentUserId.value != nil else {
            // The other silent-by-design path a developer meets. Parking the transaction is
            // correct, but "I bought something and nothing happened" needs a reason attached.
            CashSDKLog.once(
                "awaiting-identify",
                """
                A completed purchase is waiting because no user is identified yet. CashSDK will \
                not attribute a purchase to nobody, so it is held (not lost, and not finished) \
                until you call CashSDK.shared.identify(userId:), at which point it is verified \
                automatically. Call identify() as early as you know who the user is.
                """
            )
            return
        }
        guard Self.canAutomaticallySyncPurchase(userId: identity.userId, accountToken: transaction.appAccountToken) else { return }
        await noteEnvironment(transaction, using: identity.api, expectedGeneration: identity.revision)
        do {
            // Same rule as purchase(): finish ONLY after the server has durably recorded it.
            // On failure, leave it unfinished so StoreKit redelivers this update and we retry.
            _ = try await verifyAndApply(jws, expectedGeneration: generation)
            await transaction.finish()
        } catch {
            // Intentionally not finished — a redelivery (or launchBackstop) will re-report it.
            scheduleVerifyRetry()
        }
    }

    /// Report every entitlement/purchase the server may not yet know about (idempotent). Runs on
    /// identify, so a user is (about to be) known.
    private func launchBackstop(
        explicitRestore: Bool = false,
        expectedGeneration: UInt64? = nil,
        reportError: (@Sendable (Error) -> Void)? = nil
    ) async {
        guard configuration.value?.observerMode != true,
              (try? await waitUntilReady()) != nil,
              let identity = try? captureReadyIdentity() else {
            reportError?(CashSDKError.notIdentified)
            return
        }
        let owner: String? = identity.userId
        let generation = expectedGeneration ?? identity.revision
        guard owner != nil, identityGeneration.value == generation else {
            reportError?(CashSDKError.notIdentified)
            return
        }
        // Subscriptions + non-consumables: re-report current entitlements.
        for entry in await storeKit.currentEntitlements(reportError: reportError) where shouldVerify(entry.transaction) {
            guard !Task.isCancelled, identityGeneration.value == generation else {
                reportError?(Task.isCancelled ? CancellationError() : CashSDKError.notIdentified)
                return
            }
            guard explicitRestore || Self.canAutomaticallySyncPurchase(userId: owner, accountToken: entry.transaction.appAccountToken) else { continue }
            await noteEnvironment(entry.transaction, using: identity.api, expectedGeneration: identity.revision)
            do { _ = try await verifyAndApply(entry.jws, expectedGeneration: generation) }
            catch { reportError?(error) }
        }
        // Consumables are EXCLUDED from currentEntitlements, so recover them by draining every
        // UNFINISHED transaction — a purchase whose verify failed, or that arrived before identify.
        // Only runs once a user is identified (so the server can attribute), and finishes only on a
        // successful server record so nothing is lost.
        guard currentUserId.value != nil else { return }
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else {
                reportError?(CashSDKError.unverifiedTransaction(underlying: nil))
                continue
            }
            guard shouldVerify(transaction) else { continue }
            guard !Task.isCancelled, identityGeneration.value == generation else {
                reportError?(Task.isCancelled ? CancellationError() : CashSDKError.notIdentified)
                return
            }
            guard explicitRestore || Self.canAutomaticallySyncPurchase(userId: owner, accountToken: transaction.appAccountToken) else { continue }
            await noteEnvironment(transaction, using: identity.api, expectedGeneration: identity.revision)
            do {
                _ = try await verifyAndApply(result.jwsRepresentation, expectedGeneration: generation)
                await transaction.finish()
            } catch {
                // Leave unfinished — the next drain retries.
                reportError?(error)
            }
        }
    }

    /// Background recovery cannot claim a shared Apple ID's purchase for another app account.
    static func canAutomaticallySyncPurchase(userId: String?, accountToken: UUID?) -> Bool {
        guard let userId, !userId.isEmpty, let accountToken else { return false }
        return accountToken == AppAccountToken.appAccountToken(for: userId)
    }

    /// Publish a snapshot and (optionally) persist it, tagged with its owning user.
    ///
    /// Persistence goes through a SERIAL queue: bare `Task`s are unordered, so two writes in
    /// flight could land newest-first and leave a stale snapshot on disk for the next launch.
    /// If the write fails, the entitlements ETag is dropped — an ETag whose snapshot never
    /// persisted makes the next read answer `304` against an empty cache, and a paying user
    /// sees nothing until something else busts it.
    private func applySnapshot(_ entitlements: Entitlements, persist: Bool, etag: String? = nil, expectedGeneration: UInt64) {
        let owner = identityGeneration.withValue { current -> String? in
            guard current == expectedGeneration else { return nil }
            if let responseOwner = entitlements.userId, responseOwner != currentUserId.value { return nil }
            if let priorComputed = snapshot.value.computedAt, let nextComputed = entitlements.computedAt,
               snapshot.value.environment == entitlements.environment, nextComputed < priorComputed { return nil }
            if let priorVersion = snapshot.value.version, let nextVersion = entitlements.version,
               snapshot.value.environment == entitlements.environment, nextVersion < priorVersion,
               (entitlements.computedAt ?? "") <= (snapshot.value.computedAt ?? "") { return nil }
            let contextual = entitlements.withIdentity(userId: currentUserId.value, revision: current, environment: effectiveStoreEnvironment)
            snapshot.value = contextual
            broadcast(contextual, expectedGeneration: expectedGeneration)
            return currentUserId.value
        }
        guard persist, let owner else { return }
        persistQueue.enqueue { [weak self] in
            guard let self, self.identityGeneration.value == expectedGeneration else { return }
            let environment = await self.effectiveEnvironment()
            let persisted = await self.store.update(
                entitlements,
                owner: owner,
                environment: environment,
                etag: etag
            )
            if !persisted { await self.apiClient()?.clearEntitlementsETag() }
        }
    }

    /// The store environment currently in effect: the configured pin, else what StoreKit told us.
    private func effectiveEnvironment() async -> String? {
        configuration.value?.environment ?? observedEnvironment.value
    }

    /// The same value, synchronously. `internal` so the persistence tests can observe what a
    /// relaunch restored without reaching into the API client.
    var effectiveStoreEnvironment: String? {
        configuration.value?.environment ?? observedEnvironment.value
    }

    /// Learn the store environment from a verified transaction.
    ///
    /// Entitlements are resolved per environment server-side. Without this header a Sandbox /
    /// TestFlight purchase is written to `Sandbox` and then vanishes on the next entitlements
    /// read, which resolves the app default (`Production`) — every sandbox gating test fails in
    /// a way that looks like a backend bug. An explicit `configure(environment:)` always wins.
    private func noteEnvironment(_ transaction: Transaction, using api: APIClient, expectedGeneration: UInt64) async {
        guard let name = Self.environmentName(transaction) else { return }
        await adoptEnvironment(name, using: api, expectedGeneration: expectedGeneration)
    }

    /// Pin subsequent device calls to `environment`, from whichever source learned it.
    ///
    /// A host that pinned one in `configure(environment:)` always wins: it asked to be
    /// explicit, and quietly overriding that would make a QA build untestable. Otherwise the
    /// first credible answer sticks for the session, whether it came from
    /// `Transaction.environment` (iOS 16+) or from the server's verify response (any version).
    private func adoptEnvironment(_ name: String?, using api: APIClient, expectedGeneration: UInt64) async {
        guard let name, name == "Sandbox" || name == "Production" else { return }
        await api.adoptEnvironment(name)
        identityGeneration.withValue { generation in
            guard generation == expectedGeneration, configuration.value?.environment == nil,
                  observedEnvironment.value != name else { return }
            observedEnvironment.value = name
            UserDefaults.standard.set(name, forKey: Self.observedEnvironmentKey)
        }

    }

    /// `"Sandbox"` / `"Production"` — the spelling the API compares against.
    private static func environmentName(_ transaction: Transaction) -> String? {
        if #available(iOS 16.0, macOS 13.0, *) {
            switch transaction.environment {
            case .sandbox: return "Sandbox"
            case .production: return "Production"
            default: return nil // .xcode and anything Apple adds later
            }
        }
        return nil
    }

    private func broadcast(_ entitlements: Entitlements, expectedGeneration: UInt64) {
        continuations.withValue { continuations in
            for continuation in continuations.values { continuation.yield(entitlements) }
        }
        let delegate = self.delegate
        Task { @MainActor [weak self] in
            guard let self, self.identityGeneration.value == expectedGeneration, self.snapshot.value == entitlements else { return }
            delegate?.cashSDK(self, didUpdateEntitlements: entitlements)
        }
    }

    /// Skip server verification for the non-verifiable Xcode/local StoreKit environment
    /// (`08-IOS-SDK.md` §3); local entitlements still drive the UI.
    ///
    /// The iOS-15 fallback matters: `Transaction.environment` is iOS 16+, and returning `true`
    /// unconditionally meant every Xcode StoreKit-test transaction on an iOS 15 device/simulator
    /// was sent to the server, rejected, never finished, and redelivered by `Transaction.updates`
    /// forever — an infinite verify loop through the whole test session.
    private func shouldVerify(_ transaction: Transaction) -> Bool {
        if #available(iOS 16.0, macOS 13.0, *) {
            return transaction.environment != .xcode
        }
        return !Self.isXcodeEnvironmentLegacy(transaction)
    }

    /// iOS-15 spelling of `Transaction.environment`. Marked deprecated so its use of the
    /// deprecated property doesn't warn at every call site.
    @available(iOS, deprecated: 16.0, message: "Fallback for iOS 15, which has no Transaction.environment")
    private static func isXcodeEnvironmentLegacy(_ transaction: Transaction) -> Bool {
        #if os(iOS)
        return transaction.environmentStringRepresentation.caseInsensitiveCompare("xcode") == .orderedSame
        #else
        return false
        #endif
    }

    // MARK: - appAccountToken

    /// The deterministic `appAccountToken` for the current user (FR-2.2), or `nil` if
    /// no user is identified. The pure derivation lives in ``AppAccountToken`` (which mirrors the
    /// Android SDK's `AppAccountToken` and the server's `deriveAppAccountToken`).
    private func appAccountToken() -> UUID? {
        guard let userId = currentUserId.value else { return nil }
        return AppAccountToken.appAccountToken(for: userId)
    }
}
