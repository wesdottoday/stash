import Foundation
import Network

/// A long-lived Server-Sent-Events client for `GET /events`, built for a laptop's
/// intermittent connectivity (PLAN #1). It is deliberately NOT modeled on
/// `URLTitleFetcher` (whose short timeouts would kill the stream).
///
/// - A `.default` `URLSession` with a custom data-task delegate processes bytes
///   incrementally (a `.background` session can't hold an indefinite stream).
/// - `timeoutIntervalForResource` is effectively infinite (else the stream dies at
///   the 7-day default); `timeoutIntervalForRequest` (idle) is set above the relay's
///   ~20s ping; `waitsForConnectivity = false` — `NWPathMonitor` is the single owner
///   of reconnect decisions.
/// - A **ping-watchdog** (`DispatchSourceTimer`, App-Nap-resilient) fires if no byte
///   arrives within ~50s, catching a half-open socket the OS hasn't reported.
/// - Reconnect on: `didWake` (cancel the half-open task first), `NWPathMonitor`
///   path-satisfied (debounced), watchdog fire, or task completion — with
///   exponential + full-jitter backoff, reset on wake/path-up (not on immediate fail).
///
/// All state lives on `queue` (serial); delegate callbacks hop onto it. The API key
/// gates the connection; the E2E key (decrypt) is gated by the consumer, so the
/// stream stays up even when the consumer is paused for a missing key.
final class SSEClient: NSObject, URLSessionDataDelegate {
    /// A parsed "item ready" notification, delivered on `queue`.
    var onNotification: ((RelayItemMeta) -> Void)?
    /// Connection state changed (for the status surface), delivered on `queue`.
    var onConnectionChange: ((Bool) -> Void)?
    /// Provides the current write-cursor to send as `Last-Event-ID`.
    var cursorProvider: () -> Int64 = { 0 }

    private let queue = DispatchQueue(label: "today.wesdo.stash.relay.sse")
    private let opQueue: OperationQueue
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60          // idle timeout > ping interval (~20s)
        cfg.timeoutIntervalForResource = 31_536_000 // ~1 year: the stream is indefinite
        cfg.waitsForConnectivity = false            // NWPathMonitor owns reconnect
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: opQueue)
    }()

    private var running = false
    private var task: URLSessionDataTask?
    private var connected = false { didSet { if connected != oldValue { onConnectionChange?(connected) } } }

    private var buffer = Data()
    private var pendingData = ""        // accumulated `data:` lines for the current event

    private var watchdog: DispatchSourceTimer?
    private let watchdogInterval: TimeInterval = 50   // relay pings ~20s; allow misses
    private var lastByteAt = Date.distantPast

    private var backoffAttempt = 0
    private var pendingConnect: DispatchWorkItem?

    private var pathMonitor: NWPathMonitor?
    private var pathDebounce: DispatchWorkItem?

    var isConnected: Bool { queue.sync { connected } }

    override init() {
        opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.startPathMonitor()
            self.connectNow()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.pendingConnect?.cancel(); self.pendingConnect = nil
            self.cancelTaskLocked()
            self.stopWatchdog()
            self.pathMonitor?.cancel(); self.pathMonitor = nil
        }
    }

    /// `NSWorkspace.didWakeNotification`: the socket is half-open after sleep and
    /// the watchdog won't notice the wall-clock gap, so cancel and reconnect now.
    func handleDidWake() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.cancelTaskLocked()
            self.backoffAttempt = 0
            self.scheduleConnect(after: 0.3)
        }
    }

    // MARK: - Connect

    private func connectNow() {
        guard running else { return }
        cancelTaskLocked()

        guard let base = RelayCredentials.baseURL else {
            // Not enrolled yet — retry occasionally without hammering.
            scheduleConnect(after: 5)
            return
        }
        let key: String
        do {
            guard let k = try RelayCredentials.apiKey() else { scheduleConnect(after: 5); return }
            key = k
        } catch {
            // Keychain locked (pre-first-unlock) — retry later.
            scheduleConnect(after: 5)
            return
        }

        var req = URLRequest(url: base.appendingPathComponent("events"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(String(cursorProvider()), forHTTPHeaderField: "Last-Event-ID")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        buffer.removeAll(keepingCapacity: true)
        pendingData = ""
        let t = session.dataTask(with: req)
        task = t
        lastByteAt = Date()
        startWatchdog()
        t.resume()
    }

    private func scheduleConnect(after delay: TimeInterval) {
        pendingConnect?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connectNow() }
        pendingConnect = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Reconnect after a failure, with exponential + full-jitter backoff.
    private func scheduleReconnectWithBackoff() {
        guard running else { return }
        let base = 1.0, cap = 30.0
        let ceiling = min(cap, base * pow(2.0, Double(backoffAttempt)))
        backoffAttempt = min(backoffAttempt + 1, 8)
        let delay = Double.random(in: 0...ceiling)   // full jitter
        scheduleConnect(after: delay)
    }

    private func cancelTaskLocked() {
        let t = task
        task = nil
        connected = false
        stopWatchdog()
        t?.cancel()
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastByteAt) >= self.watchdogInterval {
                // No byte (not even a ping) in the window — the socket is dead.
                self.cancelTaskLocked()
                self.scheduleReconnectWithBackoff()
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: - Path monitoring

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.queue.async {
                guard let self, self.running else { return }
                guard path.status == .satisfied else { return }
                // Debounce roaming flaps; a satisfied path ≠ relay reachable.
                self.pathDebounce?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.running else { return }
                    // Only churn the connection if we're not already healthy.
                    if !self.connected || Date().timeIntervalSince(self.lastByteAt) > 22 {
                        self.backoffAttempt = 0
                        self.cancelTaskLocked()
                        self.scheduleConnect(after: 0.2)
                    }
                }
                self.pathDebounce = work
                self.queue.asyncAfter(deadline: .now() + 1.5, execute: work)
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in
            guard let self, dataTask === self.task else { return }   // ignore stale tasks
            self.lastByteAt = Date()
            self.backoffAttempt = 0          // healthy connection → reset backoff
            self.connected = true
            self.buffer.append(data)
            self.parseBuffer()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // 401/4xx come back as a normal HTTP response, not an error. Treat a
        // non-2xx status as a failed connection → backoff (don't parse its body
        // as SSE).
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            completionHandler(.cancel)
            queue.async { [weak self] in
                guard let self, dataTask === self.task else { return }
                self.cancelTaskLocked()
                self.scheduleReconnectWithBackoff()
            }
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            guard let self, (task as? URLSessionDataTask) === self.task else { return }
            self.cancelTaskLocked()
            self.scheduleReconnectWithBackoff()
        }
    }

    // MARK: - SSE parsing

    private func parseBuffer() {
        // Split on LF; keep an incomplete trailing line in the buffer.
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        if line.isEmpty {
            dispatchPendingEvent()
            return
        }
        if line.hasPrefix(":") { return }   // comment / keepalive ping
        guard let colon = line.firstIndex(of: ":") else { return }
        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data": pendingData += value
        case "id", "event": break   // event id == seq lives in the data payload too
        default: break
        }
    }

    private func dispatchPendingEvent() {
        defer { pendingData = "" }
        let payload = pendingData
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let seq = (obj["seq"] as? NSNumber)?.int64Value,
              let type = obj["type"] as? String else { return }
        let size = (obj["size"] as? NSNumber)?.int64Value ?? 0
        onNotification?(RelayItemMeta(id: id, seq: seq, type: type, size: size))
    }
}
