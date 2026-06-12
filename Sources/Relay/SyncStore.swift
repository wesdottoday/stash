import Foundation

/// The hub's durable, on-disk sync state — the load-bearing part of no-loss
/// delivery (PLAN #2). Persisted atomically to app-support (a *local* disk, never
/// the Drive-mounted vault) and mutated only from the consumer's serial queue,
/// with a lock so the status surface can read it from the main thread.
///
/// Invariants:
/// - **Cursor** = contiguous high-water mark of seqs actually handled (written
///   *or* poisoned). Sent as `Last-Event-ID` on reconnect; the relay replays
///   only `seq > cursor`, so the cursor must never advance past an item that
///   wasn't durably written or deliberately poisoned.
/// - **written-id set** (id → seq) is the idempotency oracle — checked instead of
///   probing the eventually-consistent vault mount. Pruned once `seq <= cursor`
///   (the relay will never replay it again).
/// - **poison** seqs advance the cursor (so one bad item doesn't re-replay the
///   whole backlog forever) but are NEVER acked (acking lets the relay purge the
///   evidence). Counted for the user-facing "N failed".
/// - **durable ack queue** holds ids written (or self-handled) but not yet acked,
///   independent of the cursor — a failed ack POST leaves the cursor already
///   past the item, so without this queue it would leak in the relay until TTL.
final class SyncStore: @unchecked Sendable {
    private struct State: Codable {
        var cursor: Int64 = 0
        var writtenIds: [String: Int64] = [:]    // id → seq; pruned when seq <= cursor
        var completedAboveCursor: [Int64] = []    // handled seqs > cursor (for contiguous advance)
        var pendingAcks: [String] = []            // durable ack queue (item ids)
        var selfOriginatedIds: [String] = []      // M5: ids this device produced (skip-write)
        var poisonCount: Int = 0
        var lastDrainAt: Double?                  // epoch seconds of last successful write
    }

    /// A consistent snapshot for the status surface.
    struct Stats {
        let cursor: Int64
        let pendingAckCount: Int
        let poisonCount: Int
        let lastDrainAt: Date?
    }

    private var state: State
    private let url: URL
    private let lock = NSLock()

    /// `directory` overrides the app-support location (used by tests). Production
    /// passes nil and gets `~/Library/Application Support/stash`.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("sync-state.json")

        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(State.self, from: data) {
            state = loaded
        } else {
            state = State()
        }
    }

    // MARK: - Reads

    var cursor: Int64 {
        lock.lock(); defer { lock.unlock() }
        return state.cursor
    }

    func hasWritten(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.writtenIds[id] != nil
    }

    func isSelfOriginated(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.selfOriginatedIds.contains(id)
    }

    func pendingAcks() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return state.pendingAcks
    }

    func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(cursor: state.cursor,
                     pendingAckCount: state.pendingAcks.count,
                     poisonCount: state.poisonCount,
                     lastDrainAt: state.lastDrainAt.map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: - Mutations (all persist atomically before returning)

    /// Record a durably-written item: remember its id (idempotency), enqueue its
    /// ack, mark its seq handled, and advance the cursor. Call this only AFTER the
    /// vault file is durably written (PLAN #2: never ack before the file is on disk).
    func recordWritten(id: String, seq: Int64, at when: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        state.writtenIds[id] = seq
        enqueueAckLocked(id)
        markCompletedLocked(seq)
        state.lastDrainAt = when.timeIntervalSince1970
        persistLocked()
    }

    /// A self-originated item came back over SSE: don't write it (we authored it),
    /// but still advance the cursor and ack so the relay can purge it (else a
    /// permanent cursor hole / relay leak). PLAN M5.
    func recordSelfHandled(id: String, seq: Int64) {
        lock.lock(); defer { lock.unlock() }
        state.writtenIds[id] = seq        // dedupe re-delivery
        enqueueAckLocked(id)
        markCompletedLocked(seq)
        persistLocked()
    }

    /// Mark an item terminally failed: advance the cursor past it (so it doesn't
    /// re-replay forever) but do NOT enqueue an ack (let the relay's TTL purge it,
    /// surfaced not silent). PLAN #3.
    func poison(seq: Int64) {
        lock.lock(); defer { lock.unlock() }
        state.poisonCount += 1
        markCompletedLocked(seq)
        persistLocked()
    }

    /// Remove an item from the ack queue after a successful (or already-acked) POST.
    func ackCompleted(id: String) {
        lock.lock(); defer { lock.unlock() }
        state.pendingAcks.removeAll { $0 == id }
        state.selfOriginatedIds.removeAll { $0 == id }
        persistLocked()
    }

    /// M5: remember that this device produced `id`, so when it returns over SSE we
    /// skip the write but still advance + ack.
    func recordSelfOriginated(id: String) {
        lock.lock(); defer { lock.unlock() }
        if !state.selfOriginatedIds.contains(id) {
            state.selfOriginatedIds.append(id)
            persistLocked()
        }
    }

    /// M5: a publish ultimately failed (the item never reached the relay, so no
    /// echo will come) — forget the self-originated marker so it doesn't leak.
    func removeSelfOriginated(id: String) {
        lock.lock(); defer { lock.unlock() }
        if let idx = state.selfOriginatedIds.firstIndex(of: id) {
            state.selfOriginatedIds.remove(at: idx)
            persistLocked()
        }
    }

    // MARK: - Locked helpers

    private func enqueueAckLocked(_ id: String) {
        if !state.pendingAcks.contains(id) { state.pendingAcks.append(id) }
    }

    /// Mark `seq` handled and advance the contiguous cursor as far as the
    /// completed set allows, pruning written ids the relay can no longer replay.
    private func markCompletedLocked(_ seq: Int64) {
        if seq <= state.cursor { return }   // already covered
        var completed = Set(state.completedAboveCursor)
        completed.insert(seq)
        while completed.contains(state.cursor + 1) {
            completed.remove(state.cursor + 1)
            state.cursor += 1
        }
        state.completedAboveCursor = completed.sorted()
        // Prune ids the relay can no longer replay (seq <= cursor) — BUT keep any
        // whose ack is still pending. The relay replays strictly seq > cursor, so
        // this is belt-and-suspenders: an un-acked item is still live on the relay,
        // and the written-id set is the only thing that stops a re-fetch from
        // re-writing it should it ever be re-delivered. Bounded: the set stays the
        // size of the in-flight + un-acked window.
        let pendingAckSet = Set(state.pendingAcks)
        state.writtenIds = state.writtenIds.filter { $0.value > state.cursor || pendingAckSet.contains($0.key) }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        // Atomic write to local disk: temp + rename. Survives a process crash.
        try? data.write(to: url, options: .atomic)
    }
}
