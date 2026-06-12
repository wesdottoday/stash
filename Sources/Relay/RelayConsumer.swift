import Foundation
import os

/// Live, thread-safe status for the Preferences surface. Updated by the consumer
/// (from its actor / the SSE queue), read from the main thread.
final class RelayStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var _connected = false
    private var _pending = 0
    private var _paused = false
    private var _pausedReason: String?
    private var _stalled: String?

    var connected: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _connected }
        set { lock.lock(); _connected = newValue; lock.unlock() }
    }
    var pending: Int {
        get { lock.lock(); defer { lock.unlock() }; return _pending }
        set { lock.lock(); _pending = newValue; lock.unlock() }
    }
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }
    var pausedReason: String? {
        get { lock.lock(); defer { lock.unlock() }; return _pausedReason }
        set { lock.lock(); _pausedReason = newValue; lock.unlock() }
    }
    /// Set when the head item keeps failing transiently (relay/destination
    /// unreachable) — so "Connected · N waiting" doesn't sit forever with no
    /// explanation. Cleared when an item finally drains.
    var stalled: String? {
        get { lock.lock(); defer { lock.unlock() }; return _stalled }
        set { lock.lock(); _stalled = newValue; lock.unlock() }
    }
}

/// The hub's relay consumer: holds the SSE stream and drains items into the vault
/// through a **serial, in-seq-order** pipeline (PLAN: one item at a time on a
/// dedicated context — at ~2 devices throughput is a non-issue and serial ordering
/// removes whole classes of race).
///
/// Per-item: `fetch → decrypt → write atomically+fsync → record id written →
/// advance contiguous cursor → enqueue durable ack`. Never acks before the file is
/// durably written. Classifies failures (PLAN #3):
/// - **transient** (network/5xx/timeout/locked-keychain) → backoff + retry the head;
/// - **terminal/poison** (GCM auth fail, malformed, 404-gone) → advance past it,
///   surface, never ack (let TTL purge);
/// - **not-yet-keyed** (no E2E key) → pause the pipeline, do NOT poison (else the
///   whole backlog is discarded as undecryptable).
///
/// An `actor` serializes all state; the heavy work (fetch, vault write) is awaited
/// out to URLSession / a detached Task so it never blocks the actor.
actor RelayConsumer {
    private let log = Logger(subsystem: "com.wesdottoday.stash", category: "relay")

    private let sse = SSEClient()
    private let client = RelayClient()
    private let store: SyncStore
    private let status: RelayStatus
    private let prefs: Preferences

    private var pending: [Int64: RelayItemMeta] = [:]
    private var isPumping = false
    private var pausedForKey = false
    private var isDraining = false
    private var transientAttempts = 0

    private var started = false
    private var activityToken: NSObjectProtocol?
    private var maintenanceTask: Task<Void, Never>?

    private enum Outcome { case done, retry, pauseNoKey, poisoned }

    init(store: SyncStore, status: RelayStatus, prefs: Preferences = .shared) {
        self.store = store
        self.status = status
        self.prefs = prefs
        sse.cursorProvider = { [store] in store.cursor }
        sse.onConnectionChange = { [status] connected in status.connected = connected }
        sse.onNotification = { [weak self] meta in
            Task { await self?.ingest(meta) }
        }
    }

    // MARK: - Lifecycle

    /// Start consuming if enrolled; otherwise wait for `credentialsChanged()`.
    func start() {
        guard !started else { return }
        if RelayCredentials.isEnrolled { startFully() }
    }

    func stop() {
        guard started else { return }
        started = false
        sse.stop()
        maintenanceTask?.cancel()
        maintenanceTask = nil
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    /// Enrollment completed or the E2E key appeared — (re)start or resume.
    func credentialsChanged() {
        if !started {
            if RelayCredentials.isEnrolled { startFully() }
            return
        }
        if pausedForKey {
            pausedForKey = false
            status.paused = false
            status.pausedReason = nil
            kickPump()
        }
        // The API key may have changed; force a reconnect with fresh creds.
        sse.handleDidWake()
        drainAcks()
    }

    /// `NSWorkspace.didWakeNotification`: reconnect the (half-open) SSE socket and
    /// nudge the pipeline + ack drain.
    func handleDidWake() {
        guard started else { return }
        sse.handleDidWake()
        drainAcks()
        kickPump()
    }

    private func startFully() {
        started = true
        // App Nap: keep SSE handling alive when unattended, but allow the laptop
        // to sleep on lid-close (NOT .idleSystemSleepDisabled / .latencyCritical).
        activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated],
                                                              reason: "stash relay sync")
        sse.start()
        drainAcks()
        startPeriodicMaintenance()
        kickPump()
    }

    private func startPeriodicMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.periodicTick()
            }
        }
    }

    private func periodicTick() {
        drainAcks()
        kickPump()
    }

    // MARK: - Ingest + pump

    /// A notification arrived (live or SSE backlog). Queue it (deduped) and pump.
    func ingest(_ meta: RelayItemMeta) {
        guard meta.seq > store.cursor else { return }   // already handled
        if pending[meta.seq] == nil { pending[meta.seq] = meta }
        status.pending = pending.count
        kickPump()
    }

    private func kickPump() {
        guard started, !pausedForKey, !isPumping, !pending.isEmpty else { return }
        isPumping = true
        Task { await self.pump() }
    }

    /// Process pending items strictly in ascending seq order until the queue is
    /// empty, paused, or a transient failure asks us to back off.
    ///
    /// Ordering note: notifications may `ingest` out of arrival order (each is an
    /// independent Task), but correctness holds because every iteration re-derives
    /// `pending.keys.min()` — the head is always the lowest un-handled seq. Don't
    /// "optimize" this to capture a seq outside the loop; that would break ordering.
    private func pump() async {
        while started && !pausedForKey {
            let cursor = store.cursor
            pending = pending.filter { $0.key > cursor }   // drop anything already covered
            status.pending = pending.count
            guard let seq = pending.keys.min(), let meta = pending[seq] else { break }

            let outcome = await process(meta)
            switch outcome {
            case .done, .poisoned:
                pending[seq] = nil
                transientAttempts = 0
                status.stalled = nil   // something drained → clear any "stuck head" notice
            case .pauseNoKey:
                pausedForKey = true
                status.paused = true
                status.pausedReason = "Waiting for the encryption key"
                log.info("consumer paused: no E2E key (backlog preserved)")
            case .retry:
                // Transient failure on the head — back off in place, then retry it
                // (do NOT skip ahead; that would break ordering and risk losing the
                // item). Sleeping keeps `isPumping` true so a burst of ingests can't
                // restart the pump and defeat the backoff; the actor stays responsive
                // to ingest during the suspension (it just queues into `pending`).
                let delay = transientDelay()
                if transientAttempts >= 3 {
                    status.stalled = "Retrying — relay or destination unreachable"
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        isPumping = false
        status.pending = pending.count
    }

    private func transientDelay() -> TimeInterval {
        let ceiling = min(30.0, pow(2.0, Double(transientAttempts)))
        transientAttempts = min(transientAttempts + 1, 8)
        return Double.random(in: 0.5...max(0.5, ceiling))   // full jitter
    }

    // MARK: - Per-item processing

    private func process(_ meta: RelayItemMeta) async -> Outcome {
        // Self-loop guard (M5): an item this device produced — don't re-ingest it,
        // but still advance the cursor + ack so the relay can purge it.
        if store.isSelfOriginated(id: meta.id) {
            store.recordSelfHandled(id: meta.id, seq: meta.seq)
            drainAcks()
            return .done
        }
        // Idempotent re-delivery (crash between write and cursor-persist): the file
        // is already on disk — re-advance + re-ack, never write twice.
        if store.hasWritten(id: meta.id) {
            store.recordWritten(id: meta.id, seq: meta.seq)
            drainAcks()
            return .done
        }

        // E2E key gating (PLAN #3/#4): missing → pause; locked → retry later.
        let key: Data
        do {
            guard let k = try RelayCredentials.e2eKey() else { return .pauseNoKey }
            key = k
        } catch Keychain.KeychainError.interactionNotAllowed {
            return .retry
        } catch {
            return .pauseNoKey
        }

        // Fetch.
        let blob: Data
        do {
            blob = try await client.fetchBlob(id: meta.id)
        } catch let e as RelayClient.RelayClientError {
            if e.isTransient { return .retry }
            if case .notFound = e {
                log.error("item \(meta.id, privacy: .public) gone on relay (404) — poisoning")
                store.poison(seq: meta.seq)
                return .poisoned
            }
            // unauthorized → key revoked/expired; recover on re-enroll, so retry.
            if case .unauthorized = e { return .retry }
            store.poison(seq: meta.seq)
            return .poisoned
        } catch {
            return .retry
        }

        // Decrypt (terminal on failure — wrong key / tampered / malformed).
        let payload: RelayPayload
        do {
            let type = RelayItemType(rawValue: meta.type) ?? .text
            payload = try Envelope.decrypt(blob: blob, itemId: meta.id, type: type, key: key)
        } catch {
            log.error("decrypt failed for \(meta.id, privacy: .public): \(String(describing: error), privacy: .public) — poisoning")
            store.poison(seq: meta.seq)
            return .poisoned
        }

        // Write to the vault (off-actor — the destination is a possibly-slow mount).
        let destination = prefs.destinationFolderURL
        let written = await writeToVault(payload, itemId: meta.id, destination: destination)
        guard written else { return .retry }   // unwritable destination → transient

        // Durable record THEN ack (never ack before the file is on disk, PLAN #2).
        store.recordWritten(id: meta.id, seq: meta.seq)
        drainAcks()
        return .done
    }

    private func writeToVault(_ payload: RelayPayload, itemId: String, destination: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            switch payload {
            case .markdown(let text, let sourceApp, let meta):
                return ContentHandler.saveRelayedMarkdown(
                    text: text, sourceApp: sourceApp,
                    capturedAt: meta.capturedAt, utcOffsetSeconds: meta.utcOffsetSeconds,
                    itemId: itemId, to: destination)
            case .binary(let type, let data, let filename, _, let meta):
                if type == .image {
                    return ContentHandler.saveRelayedImage(
                        data: data, capturedAt: meta.capturedAt,
                        utcOffsetSeconds: meta.utcOffsetSeconds, itemId: itemId, to: destination)
                } else {
                    return ContentHandler.saveRelayedFile(
                        data: data, filename: filename, itemId: itemId, to: destination)
                }
            case .voice(let audio, let vtt, let meta):
                return ContentHandler.saveRelayedVoice(
                    audio: audio, vtt: vtt, capturedAt: meta.capturedAt,
                    utcOffsetSeconds: meta.utcOffsetSeconds, itemId: itemId, to: destination)
            }
        }.value
    }

    // MARK: - Ack draining (durable queue, paced)

    func drainAcks() {
        guard !isDraining else { return }
        let ids = store.pendingAcks()
        guard !ids.isEmpty else { return }
        isDraining = true
        Task { await self.ackLoop(ids) }
    }

    private func ackLoop(_ ids: [String]) async {
        defer { isDraining = false }
        for id in ids {
            do {
                try await client.ack(id: id)
                store.ackCompleted(id: id)
            } catch let e as RelayClient.RelayClientError {
                switch e {
                case .rateLimited(let after):
                    // Honor Retry-After, then stop; the periodic tick resumes.
                    try? await Task.sleep(nanoseconds: UInt64((after ?? 2) * 1_000_000_000))
                    return
                case .notFound, .http:
                    // Item is gone / un-ackable — drop it from the durable queue.
                    store.ackCompleted(id: id)
                default:
                    return   // transient / unauthorized / locked → retry on next tick
                }
            } catch {
                return
            }
            // Pace acks so a post-vacation drain doesn't trip the rate limit.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
