import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

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

    /// A purchase wants a user token that outlives the App Store sheet: one that expires while
    /// the sheet is open makes the verify fail after the charge. With a ``userTokenProvider``, a
    /// token with less than this left is renewed first.
    static let minimumTokenLifetimeForPurchase: TimeInterval = 5 * 60

    /// Without a ``userTokenProvider``, a purchase still goes ahead with this much left (what
    /// `1.2.0-rc.1` hosts rely on) and logs a warning. A verify that then fails on the token
    /// leaves the transaction unfinished, and recovery reports it as this user's purchase.
    static let minimumTokenLifetimeWithoutProvider: TimeInterval = 60

    // Subsystems
    private let store: EntitlementStore
    /// Purchases started on this device, so recovery reports them with claim `purchase`.
    private let purchaseLog: PurchaseLog
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
    let eventQueue: EventQueue

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

    /// The host's token issuer. See ``userTokenProvider``.
    private let tokenProvider = Locked<(@Sendable (String) async throws -> String)?>(nil)

    /// The one pending wake-up: the earliest future `expiresAt` in the snapshot, or sooner to
    /// retry a refresh that failed at one. Replaced under the `identityGeneration` lock together
    /// with the snapshot it was computed from.
    private let expiryWakeup = Locked<Task<Void, Never>?>(nil)

    /// Failed refreshes at an `expiresAt` in a row. Reset by every snapshot that is applied.
    private let expiryRetryAttempt = Locked<Int>(0)

    /// Retries of a failed refresh at an `expiresAt`, while the app is active.
    static let maxExpiryRetries = 6

    /// The first retry's delay; it doubles each time, up to five minutes. `internal` so tests
    /// can shorten it.
    let expiryRetryBase = Locked<TimeInterval>(5)

    /// At most this many random seconds after an `expiresAt` before its refresh. `internal` so
    /// tests can remove it.
    let expiryInitialJitter = Locked<TimeInterval>(3)

    /// How long the refresh at an `expiresAt` (token renewal included) may take before access
    /// is withdrawn. `internal` so tests can shorten it.
    let expiryRefreshTimeout = Locked<TimeInterval>(10)

    /// Automatic reports wait until this moment: the server asked for a pause with `Retry-After`.
    private let retryNotBefore = Locked<Date?>(nil)

    /// A promoted In-App Purchase waiting to run.
    struct PromotedIntent: Sendable {
        let productId: String
        let receivedAt: Date
        /// Attempts that failed before reaching the App Store (offline, no product found, or no
        /// usable session).
        var failures = 0
        /// Not tried again before this moment.
        var notBefore = Date.distantPast
        /// The session could not buy: held until the next successful identify.
        var waitingForIdentify = false
    }

    private struct PromotedQueue {
        var intents: [PromotedIntent] = []
        /// One promoted purchase at a time. The next starts only after a failed one is back in
        /// the queue with its wait, so a failure can never start a lap around the queue.
        var running = false
    }

    private let promoted = Locked(PromotedQueue())

    /// Starts the promoted queue again when the next retry is due.
    private let promotedWakeup = Locked<Task<Void, Never>?>(nil)

    /// Attempts a promoted purchase gets when it keeps failing before the App Store.
    static let maxPromotedFailures = 5

    /// A promoted purchase still waiting after this long is dropped: the customer has moved on.
    static let promotedIntentLifetime: TimeInterval = 24 * 3600

    /// The first wait after a promoted purchase fails offline; it doubles each time. `internal`
    /// so tests can shorten it.
    let promotedRetryBase = Locked<TimeInterval>(10)

    /// The wait between verify retries. `internal` so tests can skip the real sleep.
    let retrySleep = Locked<@Sendable (TimeInterval) async throws -> Void>({ seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    })

    /// Delegate for entitlement updates. Set/read on the main actor.
    public weak var delegate: CashSDKDelegate?

    private let urlSession: URLSession
    private let automaticRecovery: Bool
    init(
        // Not `.shared`: see `APIClient.defaultSession()`. Its 60-second request timeout is what
        // kept a customer on a spinner for three minutes after a verify met a quiet network.
        session: URLSession = APIClient.defaultSession(),
        automaticRecovery: Bool = true,
        store: EntitlementStore = EntitlementStore(),
        purchaseLog: PurchaseLog = PurchaseLog(),
        eventQueue: EventQueue = EventQueue()
    ) {
        urlSession = session
        self.automaticRecovery = automaticRecovery
        self.store = store
        self.purchaseLog = purchaseLog
        self.eventQueue = eventQueue
    }

    deinit {
        expiryWakeup.value?.cancel()
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
            cancelExpiryWakeup()
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

    /// Start the StoreKit updates listener and the promoted-purchase listener. Nothing is
    /// drained here: recovery waits for the host to identify a user.
    private func bootstrap() async {
        // Hosts establish a fresh session on every launch. A persisted token is never proof
        // that the app has finished authenticating the current person.
        guard automaticRecovery, configuration.value?.observerMode != true else { return }
        storeKit.startListening { [weak self] transaction in
            await self?.handleUpdatedTransaction(transaction)
        }
        storeKit.startListeningForPurchaseIntents { [weak self] productId in
            self?.receivePromotedPurchase(productId: productId)
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

    /// Serve the on-disk snapshot that belongs to `userId` (and this environment) and return
    /// the ETag that describes it. A cache owned by anyone else yields nothing, never another
    /// user's entitlements.
    ///
    /// When memory already holds this user's snapshot (identified again, or a token renewed),
    /// it is at least as fresh as the disk, so it stays and only moves to this identity's
    /// revision. It is not published again: right after an `expiresAt` that would show the
    /// access ending before the server has been asked.
    private func hydrateCachedSnapshot(userId: String, generation: UInt64) async -> String? {
        // A snapshot applied just before this may still be on its way to disk.
        await persistQueue.drain()
        let cached = await store.load(for: userId, environment: await effectiveEnvironment())
        let keptInMemory = identityGeneration.withValue { current -> Bool in
            guard current == generation else { return true }
            guard snapshot.value.userId == userId || cached == .empty else { return false }
            if snapshot.value.userId == userId {
                snapshot.value = snapshot.value.withIdentity(userId: userId, revision: current, environment: effectiveStoreEnvironment)
            }
            // The wake-up set before this identify belongs to the old revision and would be
            // ignored when it fires.
            scheduleExpiryWakeup(for: snapshot.value, generation: current)
            return true
        }
        guard !keptInMemory else { return identityGeneration.value == generation ? cached.etag : nil }
        applySnapshot(cached.entitlements, persist: false, expectedGeneration: generation)
        return cached.etag
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
    ///
    /// The user's cached entitlements are served as soon as they load, before the token is
    /// checked, so an offline launch keeps its access. Identifying the same user again keeps
    /// the current snapshot on screen instead of flashing an empty one.
    public func identify(userId: String, userToken: String? = nil) {
        _ = queueIdentity(userId: userId, userToken: userToken)
    }

    private func queueIdentity(userId: String, userToken: String?) -> UInt64 {
        let generation = identityGeneration.withValue { generation -> UInt64 in
            generation &+= 1
            readyIdentity.value = nil
            identityError.value = nil
            // The same user again keeps what is on screen; the cache load that follows can only
            // confirm or refresh it. Another user must never see this one's access, not even
            // for a frame.
            if currentUserId.value != userId {
                currentUserId.value = userId
                snapshot.value = .empty
                cancelExpiryWakeup()
                broadcast(.empty, expectedGeneration: generation)
            }
            identityStore.save(userId: userId, userToken: userToken)
            return generation
        }
        installIdentity(userId: userId, userToken: userToken, generation: generation)
        return generation
    }

    private func installIdentity(userId: String, userToken: String?, generation: UInt64) {
        identityQueue.enqueue { [weak self] in
            guard let self, self.identityGeneration.value == generation else { return }
            // Cached access first. The cache is owner-keyed and offline-valid, so an offline
            // launch whose token has expired still shows what this user already had. The token
            // check below gates network calls, not cached reads.
            let cachedETag = await self.hydrateCachedSnapshot(userId: userId, generation: generation)
            do {
                guard let configuration = self.configuration.value else { throw CashSDKError.notConfigured }
                try self.validateToken(userToken, userId: userId)
                // A new client per identity: an in-flight payment keeps its original headers
                // even when a later login replaces the client's public reference.
                let api = APIClient(configuration: configuration, session: self.urlSession)
                await api.setIdentity(userId: userId, userToken: userToken)
                await api.setEnvironment(self.effectiveStoreEnvironment)
                await api.setEntitlementsETag(cachedETag)
                let identity = ReadyIdentity(userId: userId, token: userToken, revision: generation, api: api)
                self.identityGeneration.withValue { current in
                    guard current == generation else { return }
                    self.client.value = api
                    self.readyIdentity.value = identity
                }
                guard self.identityGeneration.value == generation else { return }
                self.recordEvent("identify")
                self.reconcileOnForeground()
                self.releasePromotedPurchasesWaitingForIdentify()
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

    /// ``waitUntilReady(expectedRevision:)`` without the local token check, so a purchase,
    /// restore or automatic report can renew an expired token instead of stopping.
    private func awaitReadyIdentity() async throws -> ReadyIdentity {
        let generation = identityGeneration.value
        await identityQueue.drain()
        try Task.checkCancellation()
        guard identityGeneration.value == generation else { throw CashSDKError.identityChanged }
        let identity = try captureReadyIdentity(validatingToken: false)
        guard identity.revision == generation else { throw CashSDKError.identityChanged }
        return identity
    }

    private func validateToken(_ token: String?, userId: String, minimumLifetime: TimeInterval = 0) throws {
        let host = configuration.value?.apiBase.host ?? ""
        try validateIdentityToken(token, userId: userId, minimumLifetime: minimumLifetime,
            allowUnsignedLocalIdentity: ["localhost", "127.0.0.1", "::1"].contains(host))
    }

    private func captureReadyIdentity(validatingToken: Bool = true) throws -> ReadyIdentity {
        try identityGeneration.withValue { generation in
            guard configuration.value != nil else { throw CashSDKError.notConfigured }
            if let error = identityError.value { throw error }
            guard let identity = readyIdentity.value, identity.revision == generation else {
                throw CashSDKError.notIdentified
            }
            if validatingToken { try validateToken(identity.token, userId: identity.userId) }
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

    /// Mints a fresh signed user token for `userId` when the SDK needs one: before a purchase
    /// whose token has less than five minutes left, when a purchase, restore or entitlement
    /// refresh finds the token expired, and when the server rejects the token (the call is then
    /// tried once more). The same user stays signed in and the identity revision does not
    /// change, so `identityRevision` checks against an earlier ``IdentityReadiness`` still match.
    ///
    /// Fetch the token from your backend without presenting UI (it can be called in the
    /// background) and throw if you cannot. Leave it `nil` to renew tokens yourself with
    /// ``identify(userId:userToken:)`` or ``refreshUserToken(using:)``; a purchase then needs a
    /// token with at least a minute left, and logs a warning below five minutes.
    public var userTokenProvider: (@Sendable (_ userId: String) async throws -> String)? {
        get { tokenProvider.value }
        set { tokenProvider.value = newValue }
    }

    /// Swap in a fresh token from ``userTokenProvider`` for the same user, keeping the identity
    /// revision, so a purchase in flight keeps its buyer. Throws
    /// ``CashSDKError/identityChanged`` if the account changed meanwhile.
    private func renewUserToken(for identity: ReadyIdentity) async throws -> ReadyIdentity {
        guard let provider = tokenProvider.value else { throw CashSDKError.identityTokenExpired }
        let token = try await provider(identity.userId)
        try Task.checkCancellation()
        try validateToken(token, userId: identity.userId)
        guard identityGeneration.value == identity.revision,
              await identity.api.replaceUserToken(token, for: identity.userId) else {
            throw CashSDKError.identityChanged
        }
        let renewed = ReadyIdentity(userId: identity.userId, token: token, revision: identity.revision, api: identity.api)
        let installed = identityGeneration.withValue { current -> Bool in
            guard current == identity.revision else { return false }
            if readyIdentity.value?.revision == current { readyIdentity.value = renewed }
            identityStore.save(userId: identity.userId, userToken: token)
            return true
        }
        guard installed else { throw CashSDKError.identityChanged }
        return renewed
    }

    /// `identify` was given no usable token, so no session was installed. Mint one through
    /// ``userTokenProvider`` and install it the way ``refreshUserToken(using:)`` does.
    ///
    /// Runs as the session that refresh installed, identified by the revision it returned. An
    /// identify that lands meanwhile moves the revision, and the caller gets
    /// ``CashSDKError/identityChanged`` instead of running as the account that signed in.
    private func installProvidedToken(for expectedUser: String?) async throws -> ReadyIdentity {
        guard let provider = tokenProvider.value else { throw CashSDKError.identityTokenExpired }
        let ready = try await refreshUserToken(using: provider)
        let installed = identityGeneration.withValue { current -> ReadyIdentity? in
            guard current == ready.revision, let identity = readyIdentity.value, identity.revision == current else { return nil }
            return identity
        }
        guard let identity = installed, identity.userId == ready.userId,
              expectedUser == nil || identity.userId == expectedUser else {
            throw CashSDKError.identityChanged
        }
        return identity
    }

    /// The identity a purchase or restore runs as.
    ///
    /// With a ``userTokenProvider``, a token with less than `minimumTokenLifetime` seconds left
    /// is renewed first. Without one, a token with at least `fallbackTokenLifetime` seconds left
    /// is accepted with a warning, and anything shorter throws
    /// ``CashSDKError/identityTokenExpired`` before anything reaches the App Store.
    private func identityForMoneyOperation(minimumTokenLifetime: TimeInterval, fallbackTokenLifetime: TimeInterval) async throws -> ReadyIdentity {
        var identity: ReadyIdentity
        do {
            identity = try await awaitReadyIdentity()
        } catch let error where Self.needsNewToken(error) && tokenProvider.value != nil {
            let user = currentUserId.value
            identity = try await renewedBeforeStoreKit { try await self.installProvidedToken(for: user) }
        }
        // No token at all is an unsigned loopback identity: nothing to renew.
        guard let token = identity.token,
              !tokenLasts(token, userId: identity.userId, seconds: minimumTokenLifetime) else { return identity }
        guard tokenProvider.value != nil else {
            guard tokenLasts(token, userId: identity.userId, seconds: fallbackTokenLifetime) else {
                throw CashSDKError.identityTokenExpired
            }
            CashSDKLog.warning("""
                The user token has less than five minutes left. The purchase goes ahead, but if the \
                token expires while the App Store sheet is open, the verify fails and the purchase is \
                verified later instead. Set CashSDK.shared.userTokenProvider so CashSDK can renew it.
                """)
            return identity
        }
        let current = identity
        do {
            identity = try await renewedBeforeStoreKit { try await self.renewUserToken(for: current) }
        } catch let error where Self.isUnusableToken(error) {
            // The provider could not help. The token in hand still goes as far as it would
            // without a provider: a purchase is not refused for having set one.
            guard tokenLasts(token, userId: current.userId, seconds: fallbackTokenLifetime) else { throw error }
            CashSDKLog.warning("userTokenProvider could not renew the user token; the purchase goes ahead with the current one.")
            return current
        }
        guard let renewed = identity.token,
              tokenLasts(renewed, userId: identity.userId, seconds: fallbackTokenLifetime) else {
            throw CashSDKError.identityTokenExpired
        }
        if !tokenLasts(renewed, userId: identity.userId, seconds: minimumTokenLifetime) {
            CashSDKLog.warning("userTokenProvider returned a token with less than five minutes left. Mint tokens that live longer.")
        }
        return identity
    }

    /// The identity an automatic call (an entitlement refresh, a recovery report) runs as. A
    /// token that has expired on the device is renewed through ``userTokenProvider`` when the
    /// host set one, including one that had already expired when `identify` got it.
    private func identityForBackgroundCall() async throws -> ReadyIdentity {
        let identity: ReadyIdentity
        do {
            identity = try await awaitReadyIdentity()
        } catch let error where Self.needsNewToken(error) && tokenProvider.value != nil {
            return try await installProvidedToken(for: currentUserId.value)
        }
        do {
            try validateToken(identity.token, userId: identity.userId)
            return identity
        } catch CashSDKError.identityTokenExpired where tokenProvider.value != nil {
            return try await renewUserToken(for: identity)
        }
    }

    /// An identity error that a fresh token from ``userTokenProvider`` fixes.
    private static func needsNewToken(_ error: Error) -> Bool {
        switch error {
        case CashSDKError.identityTokenExpired, CashSDKError.identityTokenRequired: return true
        default: return false
        }
    }

    /// A renewal that produced no usable token (the provider failed, or returned one that is
    /// expired or not this user's), as opposed to the account changing meanwhile.
    private static func isUnusableToken(_ error: Error) -> Bool {
        switch error {
        case CashSDKError.identityTokenExpired, CashSDKError.identityTokenInvalid: return true
        default: return false
        }
    }

    /// A renewal that fails before anything reaches the App Store cannot involve a charge, so
    /// it surfaces as the expired token it is rather than as the host's own error, which a
    /// paywall could not tell from a failure after payment. The host's error is logged.
    private func renewedBeforeStoreKit(_ renew: () async throws -> ReadyIdentity) async throws -> ReadyIdentity {
        do {
            return try await renew()
        } catch let error where !(error is CancellationError) && !Self.isIdentityError(error) {
            CashSDKLog.warning("userTokenProvider could not provide a token: \(error.localizedDescription)")
            throw CashSDKError.identityTokenExpired
        }
    }

    private func tokenLasts(_ token: String, userId: String, seconds: TimeInterval) -> Bool {
        (try? validateToken(token, userId: userId, minimumLifetime: seconds)) != nil
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
            cancelExpiryWakeup()
            identityStore.clear()
            broadcast(.empty, expectedGeneration: generation)
            // The purchase log is kept. An Ask to Buy approved while this user is signed out
            // arrives after they sign back in, and only their record gets it reported as their
            // purchase. The records name nobody, and nobody else can match them.
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
            // Not `waitUntilReady()`: a token that expired while the app was away is renewed
            // through userTokenProvider by the calls below, rather than stopping them.
            guard let self, (try? await self.awaitReadyIdentity()) != nil else { return }
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
    /// current value, then every subsequent update, including the moment an entitlement's
    /// `expiresAt` passes. Expired entitlements are never included.
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
    ///
    /// These errors come before any charge by this call: ``CashSDKError/alreadySubscribed(productId:)``,
    /// ``CashSDKError/purchaseNotAllowed``, ``CashSDKError/productUnavailable(productId:)``,
    /// ``CashSDKError/productNotFound(_:)`` and the identity errors. A cancellation that StoreKit
    /// reports as an error returns ``PurchaseResult/userCancelled``.
    /// ``CashSDKError/chargedButUnverified(transactionId:underlying:)`` means the charge happened;
    /// the transaction stays unfinished and is verified again without another purchase.
    @discardableResult
    public func purchase(_ productId: String) async throws -> PurchaseResult {
        try await runPurchase(productId, reachedStore: nil, promoted: false)
    }

    /// Purchase a StoreKit `Product` the app already holds.
    ///
    /// Same flow and same errors as ``purchase(_:)``, without the product lookup: the sheet
    /// opens with this `Product`, so an app that loads its plans from StoreKit itself does not
    /// pay for a second `Product.products(for:)` on the Buy tap. The product also goes into the
    /// SDK's cache, where ``purchase(_:)`` and a promoted purchase find it for the next five
    /// minutes.
    @discardableResult
    public func purchase(_ product: Product) async throws -> PurchaseResult {
        storeKit.remember(product)
        return try await runPurchase(product.id, reachedStore: nil, promoted: false)
    }

    /// StoreKit `Product`s for the given identifiers, with localized prices to render.
    ///
    /// The result is cached for five minutes, so a paywall that loads its plans through this
    /// call has the `Product` ready for the Buy tap, and ``purchase(_:)`` opens the sheet
    /// without asking the App Store again. Pass `fresh: true` to bypass the cache (a paywall
    /// re-opened after a storefront change). The order matches `ids`; an id the store does not
    /// know is left out, as `Product.products(for:)` leaves it out.
    public func products(for ids: [String], fresh: Bool = false) async throws -> [Product] {
        let loaded = try await storeKit.products(for: ids, fresh: fresh)
        let byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    /// The purchase flow. `reachedStore` turns true just before the payment sheet opens, so a
    /// promoted purchase can tell a failure before the App Store (safe to try again) from one
    /// after it (a charge is possible, so never buy again). A `promoted` run leaves starting the
    /// next promoted purchase to its caller, which first puts a failed one back with its wait.
    private func runPurchase(_ productId: String, reachedStore: Locked<Bool>?, promoted: Bool) async throws -> PurchaseResult {
        try purchaseOperationGate.begin()
        defer { endMoneyOperation(startingPromoted: !promoted) }
        guard configuration.value?.observerMode != true else { throw CashSDKError.observerMode }
        // A purchase before identify() has no user to attribute to: appAccountToken() is nil, so
        // StoreKit stamps no token, the server credits nobody (200 + empty entitlements),
        // verifyAndApply does NOT throw, and finish() then permanently discards the transaction —
        // a consumable paid for and lost (it's gone from currentEntitlements, so the launch
        // backstop can't recover it either). Require an identified user up front so we never
        // charge for something we cannot attribute.
        //
        // The token has to outlive the payment sheet: one that expires while the sheet is open
        // fails the verify after the charge.
        let identity = try await identityForMoneyOperation(
            minimumTokenLifetime: Self.minimumTokenLifetimeForPurchase,
            fallbackTokenLifetime: Self.minimumTokenLifetimeWithoutProvider
        )
        let buyer = identity.userId
        let generation = identity.revision
        let product = try await storeKit.purchasableProduct(productId)
        guard identityGeneration.value == generation else { throw CashSDKError.identityChanged }
        // The product lookup took time: the token still has to clear the floor as the sheet opens.
        try validateToken(identity.token, userId: buyer, minimumLifetime: Self.minimumTokenLifetimeWithoutProvider)
        try Task.checkCancellation()

        let accountToken = AppAccountToken.appAccountToken(for: buyer)
        // Written before the sheet opens. A purchase that comes back later through recovery (an
        // approved Ask-to-Buy, a verify that did not land, an app killed mid-payment) must still
        // be reported as this user's purchase, not as an automatic `sync`.
        var attempt: PurchaseLog.Attempt?
        if accountToken != nil {
            attempt = await purchaseLog.recordAttempt(productId: product.id, userId: buyer)
        }
        reachedStore?.value = true
        recordEvent("purchase_start", product: productId)
        let outcome: StorePurchaseOutcome
        do {
            outcome = try await storeKit.purchase(product, appAccountToken: accountToken)
        } catch {
            if let attempt, Self.endedBeforeCharge(error) { await purchaseLog.forget(attempt, userId: buyer) }
            guard case CashSDKError.purchaseCancelled = error else { throw error }
            // StoreKit reported the cancellation as an error rather than a result. It is the
            // same thing to the host.
            recordEvent("purchase_cancel", product: productId)
            return .userCancelled
        }

        switch outcome {
        case .userCancelled:
            if let attempt { await purchaseLog.forget(attempt, userId: buyer) }
            recordEvent("purchase_cancel", product: productId)
            return .userCancelled
        case .pending:
            // The attempt stays: the approved purchase arrives through `Transaction.updates`,
            // and is reported with claim `purchase` because of it.
            if let attempt { await purchaseLog.markPending(attempt, userId: buyer) }
            recordEvent("purchase_pending", product: productId)
            return .pending
        case .verified(let transaction):
            if transaction.isServerVerifiable {
                if let attempt { await purchaseLog.bind(attempt, to: transaction.id, userId: buyer) }
                await adoptEnvironment(transaction.environment, using: identity.api, expectedGeneration: identity.revision)
                // Verify + record with the server BEFORE finishing. finish() removes the
                // transaction from the payment queue (and from currentEntitlements for a
                // consumable), so finishing first meant a network failure here lost the
                // purchase server-side while StoreKit considered it done — a consumable could
                // never be recovered by the launch backstop. If verifyAndApply throws, we
                // leave it UNFINISHED so Transaction.updates redelivers it and we retry.
                let entitlements: Entitlements?
                do {
                    entitlements = try await verifyAndApply(transaction.jws, claim: .purchase, identity: identity, automatic: false)
                } catch {
                    // Deliberately NOT finished. Schedule a bounded in-session retry so a
                    // transient failure doesn't have to wait for the next launch or a manual
                    // restore() to be recovered. The purchase log keeps its claim `purchase`.
                    recordEvent("purchase_verify_failed", product: productId)
                    // Ownership does not change on retry; the purchase stays with its owner.
                    if case CashSDKError.purchaseBelongsToAnotherAccount = error { throw error }
                    scheduleVerifyRetry()
                    throw CashSDKError.chargedButUnverified(transactionId: transaction.id, underlying: error)
                }
                await purchaseLog.resolve(transactionId: transaction.id, userId: buyer)
                await transaction.finish()
                guard entitlements?.purchaseOutcomeConfirmed == true else {
                    throw CashSDKError.verifiedWithoutAccess(transactionId: transaction.id)
                }
                recordEvent("purchase_success", product: productId)
                return .success((entitlements ?? snapshot.value).removingExpiredAccess())
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
            if let attempt { await purchaseLog.forget(attempt, userId: buyer) }
            await transaction.finish()
            recordEvent("purchase_success", product: productId)
            return .localStoreKit
        }
    }

    /// Release the purchase/restore gate, and start a promoted purchase that was waiting for it.
    private func endMoneyOperation(startingPromoted: Bool = true) {
        purchaseOperationGate.end()
        if startingPromoted { startPendingPromotedPurchases() }
    }

    /// StoreKit refused before charging anything, so the attempt has no transaction to wait for.
    /// A network or unclassified failure keeps it: a charge is unlikely there, not ruled out.
    private static func endedBeforeCharge(_ error: Error) -> Bool {
        switch error {
        case CashSDKError.purchaseCancelled, CashSDKError.alreadySubscribed,
             CashSDKError.purchaseNotAllowed, CashSDKError.productUnavailable:
            return true
        default:
            return false
        }
    }

    /// Restore purchases: sync with the App Store, report every purchase StoreKit holds for
    /// this Apple ID, and re-resolve the server snapshot.
    ///
    /// Returns what was found, so "nothing to restore" can be told apart from a restore. Throws
    /// ``CashSDKError/restoreVerificationFailed(underlying:)`` when a purchase could not be
    /// verified and, as before, when every purchase found stays with another app account (the
    /// cause is ``CashSDKError/purchaseBelongsToAnotherAccount``). ``restoreDetailed()`` returns
    /// that case as a result instead.
    @discardableResult
    public func restore() async throws -> RestoreResult {
        let result = try await restoreDetailed()
        if result.outcome == .ownedByAnotherAccount {
            throw CashSDKError.restoreVerificationFailed(underlying: CashSDKError.purchaseBelongsToAnotherAccount)
        }
        return result
    }

    /// Restore purchases and report what was found: purchases confirmed for the signed-in
    /// account, purchases that stay with another account in this app, and purchases this restore
    /// moved here from another account under the app's `transfer` restore policy.
    ///
    /// Throws ``CashSDKError/restoreVerificationFailed(underlying:)`` when the App Store sync
    /// fails or a purchase could not be verified for a reason a retry can fix (offline, a server
    /// error, a session change), and ``CashSDKError/purchaseCancelled`` when the user cancels
    /// the App Store sign-in.
    public func restoreDetailed() async throws -> RestoreResult {
        try purchaseOperationGate.begin()
        defer { endMoneyOperation() }
        guard configuration.value?.observerMode != true else { throw CashSDKError.observerMode }
        let identity = try await identityForMoneyOperation(minimumTokenLifetime: 0, fallbackTokenLifetime: 0)
        let generation = identity.revision
        recordEvent("restore_start")
        do { try await storeKit.sync() }
        catch {
            if case CashSDKError.purchaseCancelled = error { throw error }
            throw CashSDKError.restoreVerificationFailed(underlying: error)
        }
        try Task.checkCancellation()
        guard identityGeneration.value == generation else { throw CashSDKError.notIdentified }
        // Through the backstop queue (and awaited) so this never races a launch/identify drain
        // that is already re-reporting the same transactions.
        let tally = RestoreTally()
        backstopQueue.enqueue { [weak self] in
            await self?.launchBackstop(claim: .restore, expectedGeneration: generation) { tally.record($0) }
        }
        await backstopQueue.drain()
        try Task.checkCancellation()
        guard identityGeneration.value == generation else { throw CashSDKError.notIdentified }
        if let error = tally.failure { throw CashSDKError.restoreVerificationFailed(underlying: error) }
        _ = try await refreshEntitlements()
        guard identityGeneration.value == generation else { throw CashSDKError.notIdentified }
        let result = tally.result(entitlements: entitlements)
        recordEvent("restore_success", props: [
            "restored": .number(Double(result.restoredCount)),
            "owned_by_another_account": .number(Double(result.ownedByAnotherAccountCount)),
            "transferred": .number(Double(result.transferredCount)),
        ])
        return result
    }

    // MARK: - Introductory offers

    /// Whether the signed-in Apple ID can still get `productId`'s introductory offer (a free
    /// trial or an introductory price). Check it before showing trial copy: Apple gives the
    /// offer once per subscription group, so a returning subscriber is not eligible even for a
    /// product they never bought.
    ///
    /// `false` for a product without an introductory offer, including anything that is not an
    /// auto-renewable subscription. StoreKit answers on the device; no identified user needed.
    public func isEligibleForIntroOffer(_ productId: String) async throws -> Bool {
        try await storeKit.isEligibleForIntroOffer(productId: productId)
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

    // MARK: - Promoted purchases

    /// A promoted In-App Purchase the customer started on the App Store. It runs through
    /// ``purchase(_:)`` (claim `purchase`) once a user is identified, so it is attributed like a
    /// purchase made in the app. `internal` so tests can deliver one.
    func receivePromotedPurchase(productId: String) {
        guard configuration.value?.observerMode != true else { return }
        promoted.withValue { queue in
            if !queue.intents.contains(where: { $0.productId == productId }) {
                queue.intents.append(PromotedIntent(productId: productId, receivedAt: Date()))
            }
        }
        startPendingPromotedPurchases()
    }

    /// The promoted purchases still waiting. `internal` for tests.
    var waitingPromotedPurchases: [PromotedIntent] { promoted.value.intents }

    /// The next successful identify gives a session that may be able to buy.
    private func releasePromotedPurchasesWaitingForIdentify() {
        promoted.withValue { queue in
            for index in queue.intents.indices { queue.intents[index].waitingForIdentify = false }
        }
        startPendingPromotedPurchases()
    }

    /// Start the next promoted purchase that is due, when a user is identified and no purchase,
    /// restore or other promoted purchase is running. Called on identify, when a purchase or
    /// restore ends, when a call to the API succeeds, and when a retry falls due.
    private func startPendingPromotedPurchases() {
        guard (try? captureReadyIdentity(validatingToken: false)) != nil else {
            if !promoted.value.intents.isEmpty {
                CashSDKLog.once(
                    "promoted-purchase-waiting",
                    """
                    A promoted In-App Purchase from the App Store is waiting for an identified \
                    user. It starts after CashSDK.shared.identify(userId:userToken:) completes.
                    """
                )
            }
            return
        }
        // The running purchase or restore starts the next one when it ends.
        guard !purchaseOperationGate.isBusy else { return }
        let now = Date()
        let next = promoted.withValue { queue -> PromotedIntent? in
            queue.intents.removeAll { now.timeIntervalSince($0.receivedAt) > Self.promotedIntentLifetime }
            guard !queue.running,
                  let index = queue.intents.firstIndex(where: { !$0.waitingForIdentify && $0.notBefore <= now }) else { return nil }
            queue.running = true
            return queue.intents.remove(at: index)
        }
        guard let intent = next else {
            schedulePromotedWakeup()
            return
        }
        Task { [weak self] in await self?.runPromotedPurchase(intent) }
    }

    private func runPromotedPurchase(_ intent: PromotedIntent) async {
        let reachedStore = Locked(false)
        var retry: PromotedIntent?
        do {
            _ = try await runPurchase(intent.productId, reachedStore: reachedStore, promoted: true)
        } catch {
            retry = promotedRetryIntent(intent, after: error, reachedStore: reachedStore.value)
        }
        // Back in the queue with its wait before the slot frees, so the next start cannot pick
        // it up again at once.
        promoted.withValue { queue in
            if let retry { queue.intents.insert(retry, at: 0) }
            queue.running = false
        }
        startPendingPromotedPurchases()
    }

    /// The intent to keep for another try after `error`, with its wait, or nil to drop it.
    private func promotedRetryIntent(_ intent: PromotedIntent, after error: Error, reachedStore: Bool) -> PromotedIntent? {
        var retry = intent
        switch Self.promotedRetry(after: error, reachedStore: reachedStore) {
        case .afterCurrentOperation:
            // The purchase or restore holding the gate starts it when it ends.
            return retry
        case .afterIdentify:
            retry.failures += 1
            retry.waitingForIdentify = true
        case .afterNetwork:
            retry.failures += 1
            retry.notBefore = Date().addingTimeInterval(promotedRetryDelay(failures: retry.failures))
        case .never:
            CashSDKLog.warning("Promoted purchase of \(intent.productId) did not complete: \(error.localizedDescription)")
            return nil
        }
        guard retry.failures < Self.maxPromotedFailures else {
            CashSDKLog.warning("Promoted purchase of \(intent.productId) dropped after \(retry.failures) attempts: \(error.localizedDescription)")
            return nil
        }
        return retry
    }

    /// ``promotedRetryBase`` doubling with each failure, half of it random, so devices that went
    /// offline together do not all come back at once.
    private func promotedRetryDelay(failures: Int) -> TimeInterval {
        let delay = promotedRetryBase.value * pow(2, Double(max(failures, 1) - 1))
        return delay / 2 + Double.random(in: 0...(delay / 2))
    }

    /// Wake at the earliest time a waiting promoted purchase falls due. Replaces the previous
    /// wake-up; nothing is scheduled for intents held until the next identify.
    private func schedulePromotedWakeup() {
        let due = promoted.value.intents.filter { !$0.waitingForIdentify }.map(\.notBefore).min()
        promotedWakeup.withValue { task in
            task?.cancel()
            task = nil
            guard let due, due > Date() else { return }
            task = Task { [weak self] in
                await Self.sleep(until: due)
                guard !Task.isCancelled else { return }
                self?.startPendingPromotedPurchases()
            }
        }
    }

    enum PromotedRetry: Equatable { case afterIdentify, afterCurrentOperation, afterNetwork, never }

    /// When a promoted purchase that threw may run again. Only failures before the App Store
    /// sheet are retried: after it a charge is possible, and buying again could charge twice.
    static func promotedRetry(after error: Error, reachedStore: Bool) -> PromotedRetry {
        if case CashSDKError.purchaseInProgress = error { return .afterCurrentOperation }
        guard !reachedStore else { return .never }
        if isIdentityError(error) { return .afterIdentify }
        switch error {
        case CashSDKError.network, CashSDKError.productNotFound: return .afterNetwork
        default: return .never
        }
    }

    private static func isIdentityError(_ error: Error) -> Bool {
        switch error {
        case CashSDKError.notIdentified, CashSDKError.identityTokenRequired, CashSDKError.identityTokenInvalid,
             CashSDKError.identityTokenExpired, CashSDKError.identityChanged:
            return true
        default:
            return false
        }
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
    ///
    /// A `401 invalid_user_token` is retried once with a token from ``userTokenProvider``.
    ///
    /// `automatic` is false for a purchase in flight and an explicit restore, which the user is
    /// waiting on.
    @discardableResult
    private func verifyAndApply(
        _ jws: String,
        claim: VerifyClaim,
        identity captured: ReadyIdentity? = nil,
        expectedGeneration: UInt64? = nil,
        automatic: Bool = true
    ) async throws -> Entitlements? {
        var identity = try await reportingIdentity(captured, expectedGeneration: expectedGeneration)
        if automatic, let notBefore = retryNotBefore.value, notBefore > Date() {
            // The server asked for a pause. An automatic report waits it out and leaves the
            // transaction unfinished for the recovery pass scheduled after it.
            throw CashSDKError.server(status: 429, code: "rate_limited", message: nil)
        }
        let outcome: APIClient.VerifyOutcome
        do {
            outcome = try await verifyWithRetry(jws, claim: claim, api: identity.api)
        } catch let error where Self.isRejectedUserToken(error) && tokenProvider.value != nil {
            // The server no longer accepts the token, most often because it expired while the
            // payment sheet was open. Renew it for the same user and report once more. If that
            // fails too, the transaction stays unfinished and is recovered later.
            identity = try await renewUserToken(for: identity)
            outcome = try await verifyWithRetry(jws, claim: claim, api: identity.api)
        }
        let api = identity.api
        let owner = identity.userId
        let generation = identity.revision
        try requirePurchaseAttribution(attributed: outcome.attributed,
                                       belongsToAnotherAccount: outcome.entitlements?.belongsToAnotherAccount)
        if let responseOwner = outcome.entitlements?.userId, responseOwner != owner {
            throw CashSDKError.invalidResponse
        }
        // Connectivity is provably back — drain any telemetry backlog sitting out a backoff.
        connectivityConfirmed()
        // Adopt the environment the SERVER resolved this purchase into, before applying the
        // snapshot. Callers already adopt `Transaction.environment` read locally,
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

    /// The identity a report is made as. A captured one (a purchase) is used as is: its token
    /// was checked before the payment sheet, and the server has the last word. Otherwise the
    /// current identity, with a locally expired token renewed through ``userTokenProvider``
    /// when one is set.
    private func reportingIdentity(_ captured: ReadyIdentity?, expectedGeneration: UInt64?) async throws -> ReadyIdentity {
        let identity = try captured ?? captureReadyIdentity(validatingToken: false)
        if let expectedGeneration, expectedGeneration != identity.revision { throw CashSDKError.identityChanged }
        guard captured == nil else { return identity }
        do {
            try validateToken(identity.token, userId: identity.userId)
            return identity
        } catch CashSDKError.identityTokenExpired where tokenProvider.value != nil {
            return try await renewUserToken(for: identity)
        }
    }

    private func verifyWithRetry(_ jws: String, claim: VerifyClaim, api: APIClient) async throws -> APIClient.VerifyOutcome {
        try await Self.retrying(sleep: retrySleep.value, onRetryAfter: { [weak self] in self?.noteRetryAfter($0) }) {
            try await api.verify(signedTransaction: jws, claim: claim)
        }
    }

    /// Remember how long the server asked us to back off, so automatic reports and the
    /// scheduled recovery pass wait for it.
    private func noteRetryAfter(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(min(max(0, seconds), Self.maxAutomaticPause))
        retryNotBefore.withValue { current in
            if (current ?? .distantPast) < until { current = until }
        }
    }

    /// `401 invalid_user_token` (verify) or `401 unauthenticated_user` (entitlement reads): the
    /// server does not accept the signed user token (expired, revoked, or signed with a
    /// rotated-out secret).
    static func isRejectedUserToken(_ error: Error) -> Bool {
        guard case let CashSDKError.server(status, code, _) = error, status == 401 else { return false }
        return code == "invalid_user_token" || code == "unauthenticated_user"
    }

    /// Re-read the server snapshot (`GET /v1/entitlements`). Requires an identified user. An
    /// expired or rejected token is renewed through ``userTokenProvider`` when one is set.
    @discardableResult
    public func refreshEntitlements() async throws -> Entitlements? {
        try await fetchAndApplyEntitlements(revalidate: true).entitlements
    }

    /// Fetch the snapshot and apply it. `applied` says whether it became the current one; it
    /// stays false for a `304` and for an answer older than what is already shown.
    private func fetchAndApplyEntitlements(revalidate: Bool) async throws -> (entitlements: Entitlements?, applied: Bool) {
        var identity = try await identityForBackgroundCall()
        let entitlements: Entitlements?
        do {
            entitlements = try await readEntitlements(identity.api, revalidate: revalidate)
        } catch let error where Self.isRejectedUserToken(error) && tokenProvider.value != nil {
            identity = try await renewUserToken(for: identity)
            entitlements = try await readEntitlements(identity.api, revalidate: revalidate)
        }
        guard identityGeneration.value == identity.revision else { throw CashSDKError.identityChanged }
        connectivityConfirmed()
        guard let entitlements else { return (nil, false) }
        let etag = await identity.api.entitlementsETag()
        return (entitlements, applySnapshot(entitlements, persist: true, etag: etag, expectedGeneration: identity.revision))
    }

    /// The entitlement read. A throttled answer's `Retry-After` pauses automatic calls, the
    /// retries of a refresh at an `expiresAt` included.
    private func readEntitlements(_ api: APIClient, revalidate: Bool) async throws -> Entitlements? {
        do {
            return try await api.fetchEntitlements(revalidate: revalidate)
        } catch let throttled as APIClient.Throttled {
            if let retryAfter = throttled.retryAfter { noteRetryAfter(retryAfter) }
            throw throttled.error
        }
    }

    /// A call to the API just succeeded: drain a telemetry backlog and start a promoted
    /// purchase that failed while offline.
    private func connectivityConfirmed() {
        networkDidSucceed()
        startPendingPromotedPurchases()
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
    /// waiting for the next launch or a manual `restore()`. Never sooner than a `Retry-After`
    /// the server sent, and jittered so devices throttled together do not return together.
    private func scheduleVerifyRetry() {
        let attempt = backstopRetries.withValue { $0 += 1; return $0 }
        guard attempt <= 3 else { return }
        let serverPause = max(0, retryNotBefore.value?.timeIntervalSinceNow ?? 0)
        let delay = max(TimeInterval(attempt) * 15, serverPause) + Double.random(in: 0...3)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * Double(NSEC_PER_SEC)))
            guard let self, self.currentUserId.value != nil else { return }
            self.enqueueBackstop()
        }
    }

    /// Handle a verified transaction from the `Transaction.updates` listener. `internal` so
    /// tests can deliver one.
    func handleUpdatedTransaction(_ transaction: StoreTransaction) async {
        guard configuration.value?.observerMode != true,
              let identity = try? await awaitReadyIdentity() else { return }
        let generation = identity.revision
        guard transaction.isServerVerifiable else {
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
        await adoptEnvironment(transaction.environment, using: identity.api, expectedGeneration: generation)
        // `purchase` for one this user started here (an approved Ask-to-Buy, a purchase whose
        // verify did not land), `sync` for a renewal or anything bought elsewhere.
        let claim = await purchaseLog.claim(for: transaction, userId: identity.userId)
        do {
            // Same rule as purchase(): finish ONLY after the server has durably recorded it.
            // On failure, leave it unfinished so StoreKit redelivers this update and we retry.
            _ = try await verifyAndApply(transaction.jws, claim: claim, expectedGeneration: generation)
            await purchaseLog.resolve(transactionId: transaction.id, userId: identity.userId)
            await transaction.finish()
        } catch CashSDKError.purchaseBelongsToAnotherAccount {
            // Another account in this app keeps it under the restore policy, so retrying cannot
            // change the answer. It stays unfinished until its owner signs in here or this user
            // restores.
        } catch {
            // Intentionally not finished — a redelivery (or launchBackstop) will re-report it.
            scheduleVerifyRetry()
        }
    }

    /// Report every entitlement/purchase the server may not yet know about (idempotent). Runs on
    /// identify, so a user is (about to be) known.
    ///
    /// `claim` is `.restore` only for an explicit restore, which may report any purchase on this
    /// Apple ID. An automatic pass (`.sync`) reports only the purchases this account could own
    /// (its own app account token, or none at all), each with `purchase` when this device
    /// started it for this user and `sync` otherwise. `internal` so tests can run a pass.
    func launchBackstop(
        claim: VerifyClaim = .sync,
        expectedGeneration: UInt64? = nil,
        report: (@Sendable (BackstopReport) -> Void)? = nil
    ) async {
        guard configuration.value?.observerMode != true,
              let identity = try? await awaitReadyIdentity() else {
            report?(.failed(CashSDKError.notIdentified))
            return
        }
        let owner = identity.userId
        let generation = expectedGeneration ?? identity.revision
        guard identityGeneration.value == generation else {
            report?(.failed(CashSDKError.notIdentified))
            return
        }
        let explicitRestore = claim == .restore
        let reportError: @Sendable (Error) -> Void = { report?(.failed($0)) }
        // Whether the server confirmed a transaction earlier in this pass, by id, so the
        // unfinished drain does not report the same one twice.
        var confirmed: [String: Bool] = [:]
        // Subscriptions + non-consumables: re-report current entitlements.
        for entry in await storeKit.currentEntitlements(reportError: reportError) where entry.isServerVerifiable {
            guard !Task.isCancelled, identityGeneration.value == generation else {
                report?(.failed(Task.isCancelled ? CancellationError() : CashSDKError.notIdentified))
                return
            }
            guard explicitRestore || Self.canAutomaticallySyncPurchase(userId: owner, accountToken: entry.appAccountToken) else { continue }
            confirmed[entry.id] = await reportTransaction(entry, restoring: explicitRestore, owner: owner, api: identity.api, generation: generation, report: report)
        }
        // Consumables are EXCLUDED from currentEntitlements, so recover them by draining every
        // UNFINISHED transaction — a purchase whose verify failed, or that arrived before identify.
        // Only runs once a user is identified (so the server can attribute), and finishes only on a
        // successful server record so nothing is lost.
        guard currentUserId.value != nil else { return }
        for entry in await storeKit.unfinishedTransactions(reportError: reportError) where entry.isServerVerifiable {
            guard !Task.isCancelled, identityGeneration.value == generation else {
                report?(.failed(Task.isCancelled ? CancellationError() : CashSDKError.notIdentified))
                return
            }
            if let wasConfirmed = confirmed[entry.id] {
                if wasConfirmed { await entry.finish() }
                continue
            }
            guard explicitRestore || Self.canAutomaticallySyncPurchase(userId: owner, accountToken: entry.appAccountToken) else { continue }
            if await reportTransaction(entry, restoring: explicitRestore, owner: owner, api: identity.api, generation: generation, report: report) {
                await entry.finish()
            }
            // Otherwise it stays unfinished for the next drain to retry.
        }
    }

    /// Verify one transaction and say whether the server confirmed it for this account.
    ///
    /// An explicit restore reports everything with `restore`. An automatic pass uses the purchase
    /// log: `purchase` for a purchase this device started for `owner`, `sync` otherwise.
    private func reportTransaction(
        _ transaction: StoreTransaction,
        restoring: Bool,
        owner: String,
        api: APIClient,
        generation: UInt64,
        report: (@Sendable (BackstopReport) -> Void)?
    ) async -> Bool {
        await adoptEnvironment(transaction.environment, using: api, expectedGeneration: generation)
        // Asked on a restore too, so an attempt it satisfies is bound and not matched again.
        let logged = await purchaseLog.claim(for: transaction, userId: owner)
        do {
            let entitlements = try await verifyAndApply(transaction.jws, claim: restoring ? .restore : logged,
                                                        expectedGeneration: generation, automatic: !restoring)
            await purchaseLog.resolve(transactionId: transaction.id, userId: owner)
            report?(.confirmed(transactionId: transaction.id, transferred: entitlements?.transferredFromAnotherAccount == true))
            return true
        } catch CashSDKError.purchaseBelongsToAnotherAccount {
            report?(.ownedByAnotherAccount(transactionId: transaction.id))
            return false
        } catch {
            report?(.failed(error))
            return false
        }
    }

    /// Background recovery cannot claim a shared Apple ID's purchase for another app account.
    ///
    /// A transaction with another account's token stays with that account. One with no token
    /// at all (an offer code redeemed in the App Store, a promoted purchase, a family-shared
    /// copy) is reported: it goes out with claim `sync`, which the server uses to credit this
    /// user only when nobody owns the purchase yet, and never to move it. Deliberately, an
    /// unowned one therefore goes to whoever is signed in on this device, as it already did on
    /// a manual Restore.
    static func canAutomaticallySyncPurchase(userId: String?, accountToken: UUID?) -> Bool {
        guard let userId, !userId.isEmpty else { return false }
        guard let accountToken else { return true }
        return accountToken == AppAccountToken.appAccountToken(for: userId)
    }

    /// Publish a snapshot and (optionally) persist it, tagged with its owning user.
    ///
    /// Persistence goes through a SERIAL queue: bare `Task`s are unordered, so two writes in
    /// flight could land newest-first and leave a stale snapshot on disk for the next launch.
    /// If the write fails, the entitlements ETag is dropped — an ETag whose snapshot never
    /// persisted makes the next read answer `304` against an empty cache, and a paying user
    /// sees nothing until something else busts it.
    ///
    /// Returns whether `entitlements` became the current snapshot.
    @discardableResult
    private func applySnapshot(_ entitlements: Entitlements, persist: Bool, etag: String? = nil, expectedGeneration: UInt64) -> Bool {
        let applied = identityGeneration.withValue { current -> (owner: String?, applied: Bool) in
            guard current == expectedGeneration else { return (nil, false) }
            if let responseOwner = entitlements.userId, responseOwner != currentUserId.value { return (nil, false) }
            if let priorComputed = snapshot.value.computedAt, let nextComputed = entitlements.computedAt,
               snapshot.value.environment == entitlements.environment, nextComputed < priorComputed { return (nil, false) }
            if let priorVersion = snapshot.value.version, let nextVersion = entitlements.version,
               snapshot.value.environment == entitlements.environment, nextVersion < priorVersion,
               (entitlements.computedAt ?? "") <= (snapshot.value.computedAt ?? "") { return (nil, false) }
            // The transaction flags reached the purchase or restore result that carried them.
            // Kept here, they would be replayed to every new subscriber and at every expiry.
            let contextual = entitlements
                .withIdentity(userId: currentUserId.value, revision: current, environment: effectiveStoreEnvironment)
                .clearingTransactionFlags()
            snapshot.value = contextual
            expiryRetryAttempt.value = 0
            broadcast(contextual, expectedGeneration: expectedGeneration)
            scheduleExpiryWakeup(for: contextual, generation: current)
            return (currentUserId.value, true)
        }
        guard persist, let owner = applied.owner else { return applied.applied }
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
        return true
    }

    // MARK: - Expiry

    /// Wake at the earliest future `expiresAt` in `entitlements` (plus a few random seconds, so
    /// devices whose access expires together do not all ask at once), or at `retryAt` when that
    /// comes first, replacing any earlier wake-up. Called with the `identityGeneration` lock
    /// held, right after `entitlements` became the snapshot, so the wake-up always matches the
    /// snapshot being shown.
    private func scheduleExpiryWakeup(for entitlements: Entitlements, generation: UInt64, retryAt: Date? = nil) {
        let deadline = entitlements.nextExpiry()
            .map { $0.addingTimeInterval(Double.random(in: 0...max(0, expiryInitialJitter.value))) }
        let isRetry = retryAt.map { retry in deadline.map { retry < $0 } ?? true } ?? false
        let wakeup = (isRetry ? retryAt : deadline).map { date in
            Task { [weak self] in
                await Self.sleep(until: date)
                guard !Task.isCancelled else { return }
                await self?.expiryReached(generation: generation, isRetry: isRetry)
            }
        }
        expiryWakeup.withValue { current in
            current?.cancel()
            current = wakeup
        }
    }

    private func cancelExpiryWakeup() {
        expiryWakeup.withValue { current in
            current?.cancel()
            current = nil
        }
        expiryRetryAttempt.value = 0
    }

    /// An entitlement's `expiresAt` has passed, or a failed refresh is due for another try.
    ///
    /// The server is asked first, for a full answer (no `If-None-Match`, since a `304` would
    /// only confirm the snapshot whose deadline just passed) and with the token renewed through
    /// ``userTokenProvider`` when needed. A renewal normally reached the server before this
    /// moment (its `expiresAt` already includes the renewal grace), and publishing the loss
    /// first would flash access off and on. When the server cannot be asked within
    /// ``expiryRefreshTimeout``, the snapshot without the expired access goes out (fail closed),
    /// with bounded retries while the app is in the foreground. An answer that arrives after the
    /// timeout still applies.
    private func expiryReached(generation: UInt64, isRetry: Bool) async {
        let owner = identityGeneration.withValue { current -> String? in
            // Cancelled means a newer snapshot or an identity change replaced this wake-up.
            // Replacements happen under this same lock, so the check cannot race them.
            guard current == generation, !Task.isCancelled else { return nil }
            // This wake-up is spent. Let go of it without cancelling it: scheduling the next one
            // would otherwise cancel this task, and with it the refresh below.
            expiryWakeup.value = nil
            return currentUserId.value
        }
        guard let owner else { return }
        if isRetry, !(await Self.isApplicationInForeground()) {
            // Retrying is for an app on screen; the refresh on the next foreground takes over.
            // The loss is already published. Keep the wake-up for the next deadline.
            expiryRetryAttempt.value = 0
            expiryFallback(owner: owner, publish: false, retry: false)
            return
        }
        do {
            // A snapshot that is applied publishes itself and sets the next wake-up.
            let applied = try await Self.withTimeout(expiryRefreshTimeout.value) { [self] in
                try await fetchAndApplyEntitlements(revalidate: false).applied
            }
            guard applied else {
                // Answered without anything newer than the snapshot on screen, so its deadline
                // stands: publish it without the expired access, and do not ask again.
                expiryRetryAttempt.value = 0
                expiryFallback(owner: owner, publish: true, retry: false)
                return
            }
        } catch {
            // Fail closed: nothing proves the access continues.
            expiryFallback(owner: owner, publish: true, retry: true)
        }
    }

    /// Publish the snapshot as the device sees it now, without expired access, and set the next
    /// wake-up: the next deadline, or sooner for a retry of the refresh while retries remain.
    /// Skipped when another user signed in meanwhile; a token renewed for the same user moved
    /// the revision, and the current one is used.
    private func expiryFallback(owner: String, publish: Bool, retry: Bool) {
        identityGeneration.withValue { current in
            guard currentUserId.value == owner else { return }
            if publish { broadcast(snapshot.value, expectedGeneration: current) }
            scheduleExpiryWakeup(for: snapshot.value, generation: current, retryAt: retry ? nextExpiryRetry() : nil)
        }
    }

    /// When to try a failed refresh at an `expiresAt` again, or nil once the retries are spent.
    /// Full jitter up to ``expiryRetryBase`` doubling (at most five minutes), and never before a
    /// `Retry-After` the server sent.
    private func nextExpiryRetry() -> Date? {
        let attempt = expiryRetryAttempt.withValue { $0 += 1; return $0 }
        guard attempt <= Self.maxExpiryRetries else { return nil }
        let ceiling = min(expiryRetryBase.value * pow(2, Double(attempt - 1)), 300)
        let backoff = Double.random(in: 0...ceiling)
        let serverPause = max(0, retryNotBefore.value?.timeIntervalSinceNow ?? 0)
        let wait = serverPause > 0 ? max(backoff, serverPause + Double.random(in: 0...1)) : backoff
        return Date().addingTimeInterval(wait)
    }

    /// Whether the app is on screen. `.inactive` counts: Control Center, a call banner or the
    /// payment sheet over the app leave it there.
    @MainActor
    private static func isApplicationInForeground() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        return UIApplication.shared.applicationState != .background
        #else
        return true
        #endif
    }

    /// `operation`'s result, or a timeout after `seconds`, whichever comes first. At the timeout
    /// the caller moves on and the operation is left to finish by itself, so a host callback
    /// that never returns cannot hold the caller, and a late answer still takes effect.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let finished = Locked(false)
        let claim: @Sendable () -> Bool = {
            finished.withValue { done in
                defer { done = true }
                return !done
            }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Task {
                let result: Result<T, Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                if claim() { continuation.resume(with: result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if claim() { continuation.resume(throwing: CashSDKError.network(underlying: URLError(.timedOut))) }
            }
        }
    }

    /// Sleep until `deadline` by the wall clock, in slices of at most a minute: the task clock
    /// can stop while the device sleeps, and one long sleep would then overshoot the deadline.
    static func sleep(until deadline: Date) async {
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(min(remaining, 60) * 1_000_000_000))
        }
    }

    // MARK: - Environment

    /// The store environment currently in effect: the configured pin, else what StoreKit told us.
    private func effectiveEnvironment() async -> String? {
        configuration.value?.environment ?? observedEnvironment.value
    }

    /// The same value, synchronously. `internal` so the persistence tests can observe what a
    /// relaunch restored without reaching into the API client.
    var effectiveStoreEnvironment: String? {
        configuration.value?.environment ?? observedEnvironment.value
    }

    /// Pin subsequent device calls to `environment`, from whichever source learned it.
    ///
    /// Entitlements are resolved per environment server-side. Without this header a Sandbox /
    /// TestFlight purchase is written to `Sandbox` and then vanishes on the next entitlements
    /// read, which resolves the app default (`Production`) — every sandbox gating test fails in
    /// a way that looks like a backend bug.
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

    /// Publish `entitlements` to the stream and the delegate. Observers see what
    /// ``entitlements`` returns: only unexpired entitlements, with the tier recomputed from them.
    private func broadcast(_ entitlements: Entitlements, expectedGeneration: UInt64) {
        let visible = entitlements.removingExpiredAccess()
        continuations.withValue { continuations in
            for continuation in continuations.values { continuation.yield(visible) }
        }
        let delegate = self.delegate
        Task { @MainActor [weak self] in
            guard let self, self.identityGeneration.value == expectedGeneration, self.snapshot.value == entitlements else { return }
            delegate?.cashSDK(self, didUpdateEntitlements: entitlements.removingExpiredAccess())
        }
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
