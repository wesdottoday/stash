import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private var captureWindow: CaptureWindow!
    private var hotkey: HotkeyManager!
    private var menuBar: MenuBarController!
    private var preferencesController: PreferencesWindowController?

    // Voice capture (M1): held singletons, pre-allocated like the capture
    // window so the toast appears instantly when the voice chord fires.
    private var voiceController: VoiceController!
    private var voiceToast: VoiceToastPanel!

    // Enrollment (M2): the QR window for "Link a device" is held so it isn't
    // released while shown.
    private var qrWindowController: QRWindowController?

    // Relay consumer (M3+): the hub's SSE-driven, no-loss drain pipeline. Held
    // singletons; the durable sync state + live status outlive the consumer.
    private let syncStore = SyncStore()
    private let relayStatus = RelayStatus()
    private var relayConsumer: RelayConsumer!
    private var relayProducer: RelayProducer!

    private var isWindowVisible = false
    private var pendingSourceApp: String?

    // Snapshot of the last-applied preference values, so we can tell which
    // keys actually changed when UserDefaults.didChangeNotification fires.
    private var snapMenuBarEnabled: Bool = true
    private var snapHotkeyKeyCode: UInt32 = 0
    private var snapHotkeyModifiers: NSEvent.ModifierFlags = []
    private var snapVoiceHotkeyKeyCode: UInt32 = 0
    private var snapVoiceHotkeyModifiers: NSEvent.ModifierFlags = []
    private var snapDestinationFolder: String = ""

    // Periodic sync so out-of-process `defaults write` from the CLI is
    // picked up — UserDefaults' in-memory cache doesn't always notice when
    // the plist is rewritten beneath us, so didChangeNotification alone is
    // insufficient.
    private var defaultsSyncTimer: Timer?
    private let defaultsSyncInterval: TimeInterval = 2.0

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register the `stash://` URL-scheme handler before the app is fully up
        // so an enrollment deep link that launches us is delivered. Custom
        // schemes arrive as a GetURL Apple Event (not application(_:open:)).
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pre-create the capture window so the hotkey is instant.
        captureWindow = CaptureWindow()
        captureWindow.onSubmit = { [weak self] payload in self?.handleSubmit(payload) }
        captureWindow.onDismiss = { [weak self] in self?.dismissWindow(saved: false) }
        captureWindow.onPositionChange = { [weak self] origin in
            self?.prefs.windowPosition = origin
        }

        // Pre-warm destination
        _ = ContentHandler.ensureDirectory(prefs.destinationFolderURL)

        // Menu bar
        menuBar = MenuBarController()
        menuBar.onPreferences = { [weak self] in self?.showPreferences() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        applyMenuBarVisibility(prefs.menuBarEnabled)

        // Voice capture (pre-allocated; the toast must be instant on the chord).
        voiceToast = VoiceToastPanel()
        voiceController = VoiceController()
        wireVoice()

        // Relay consumer + producer share the SAME SyncStore so the producer's
        // self-originated markers are visible to the consumer's echo guard.
        relayConsumer = RelayConsumer(store: syncStore, status: relayStatus)
        relayProducer = RelayProducer(store: syncStore)
        Task { await relayConsumer.start() }

        // Hotkey
        hotkey = HotkeyManager()
        hotkey.onHotkey = { [weak self] in self?.handleHotkey() }
        hotkey.onVoiceHotkey = { [weak self] in self?.voiceController.toggle() }
        hotkey.registerCapture(keyCode: prefs.hotkeyKeyCode, cocoaModifiers: prefs.hotkeyModifiers)
        hotkey.registerVoice(keyCode: prefs.voiceHotkeyKeyCode, cocoaModifiers: prefs.voiceHotkeyModifiers)

        // Reapply registrations when the system wakes from sleep, and finalize
        // any recording that was force-flushed to disk on sleep (#6).
        let wsNC = NSWorkspace.shared.notificationCenter
        wsNC.addObserver(forName: NSWorkspace.didWakeNotification,
                         object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.hotkey.registerCapture(keyCode: self.prefs.hotkeyKeyCode,
                                        cocoaModifiers: self.prefs.hotkeyModifiers)
            self.hotkey.registerVoice(keyCode: self.prefs.voiceHotkeyKeyCode,
                                      cocoaModifiers: self.prefs.voiceHotkeyModifiers)
            self.voiceController.recoverOrphansIfIdle()
            Task { await self.relayConsumer.handleDidWake() }
        }

        // The pre-suspend window is too short to remux, so force-flush the
        // working file to disk on sleep; recovery (above / on launch) finishes
        // it. (Resilience #6.)
        wsNC.addObserver(forName: NSWorkspace.willSleepNotification,
                         object: nil, queue: .main) { [weak self] _ in
            self?.voiceController.handleWillSleep()
        }

        // Pick up external preference changes (`defaults write …`) live.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        cachePreferenceSnapshot()
        startDefaultsSyncTimer()

        // Finalize any voice recording left behind by a crash or a previous
        // sleep-forced flush. (Resilience #6 — launch crash-recovery.)
        voiceController.recoverOrphansIfIdle()

        // First launch: show preferences.
        if !prefs.hasLaunchedBefore {
            prefs.hasLaunchedBefore = true
            showPreferences()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        defaultsSyncTimer?.invalidate()
        defaultsSyncTimer = nil
        // If a recording is live, flush it to disk so it's recovered on next
        // launch rather than lost (a clean commit can't be awaited here).
        voiceController?.handleWillSleep()
        hotkey?.unregisterAll()
        menuBar?.uninstall()
    }

    // MARK: - Voice wiring ----------------------------------------------------

    private func wireVoice() {
        voiceController.onPhaseChange = { [weak self] phase in
            self?.handleVoicePhase(phase)
        }
        voiceController.onLevel = { [weak self] level in
            self?.voiceToast.setLevel(level)
        }
        voiceController.onLiveLine = { [weak self] line in
            self?.voiceToast.setLiveLine(line)
        }
        voiceController.onStarted = { [weak self] date in
            self?.voiceToast.startRecording(from: date)
        }
        voiceController.onError = { [weak self] message in
            self?.voiceToast.showError(message)
            self?.menuBar.updateIcon(isRecording: false)
        }
        voiceController.onPublish = { [weak self] audio, vtt, capturedAt in
            self?.relayProducer.publishVoice(audio: audio, vtt: vtt, capturedAt: capturedAt)
        }
        voiceToast.onStop = { [weak self] in self?.voiceController.requestStopSaving() }
        voiceToast.onDiscard = { [weak self] in self?.voiceController.requestDiscard() }
    }

    private func handleVoicePhase(_ phase: VoiceController.Phase) {
        switch phase {
        case .preparing:
            voiceToast.showPreparing()
            menuBar.updateIcon(isRecording: true)
        case .recording:
            menuBar.updateIcon(isRecording: true)
        case .finalizing:
            voiceToast.showFinalizing()   // "Saving…" — no Stop/discard (point of no return)
        case .idle:
            voiceToast.hide()
            menuBar.updateIcon(isRecording: false)
        }
    }

    // MARK: - Enrollment (M2) -------------------------------------------------

    /// Apple Event handler for incoming `stash://` URLs (the registered scheme).
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                         withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        handleStashURL(url)
    }

    private func handleStashURL(_ url: URL) {
        guard Enrollment.isEnrollmentLink(url) else { return }
        Task { @MainActor in
            let result = await Enrollment.handleDeepLink(url)
            switch result {
            case .success(let summary):
                self.preferencesController?.refreshRelayStatus()
                Task { await self.relayConsumer.credentialsChanged() }
                let role = summary.isCustodian
                    ? "This Mac is the encryption-key custodian."
                    : "This Mac joined an existing key custodian."
                self.showInfoAlert(
                    title: "Enrolled with relay",
                    message: "Connected to \(summary.relayHost).\n\(role)"
                )
            case .failure(let error):
                self.showInfoAlert(title: "Enrollment failed", message: String(describing: error))
            }
        }
    }

    /// "Link a device" from Preferences → mint a token + render the QR.
    private func linkADevice() {
        Task { @MainActor in
            let result = await Enrollment.createLinkURL()
            switch result {
            case .success(let url):
                if self.qrWindowController == nil { self.qrWindowController = QRWindowController() }
                if self.qrWindowController?.present(url: url) != true {
                    self.showInfoAlert(title: "Couldn't show the code",
                                       message: "The QR code couldn't be generated.")
                }
            case .failure(let error):
                self.showInfoAlert(title: "Couldn't link a device", message: String(describing: error))
            }
        }
    }

    /// One-line live relay/consumer status for the Preferences Sync row.
    private func composeRelayStatusLine() -> String {
        let stats = syncStore.stats()
        var parts: [String] = []
        if relayStatus.paused, let reason = relayStatus.pausedReason {
            parts.append("Paused — \(reason)")
        } else if let stalled = relayStatus.stalled {
            parts.append(stalled)
        } else {
            parts.append(relayStatus.connected ? "Connected" : "Offline")
        }
        let pending = relayStatus.pending
        if pending > 0 { parts.append("\(pending) waiting") }
        if stats.poisonCount > 0 { parts.append("\(stats.poisonCount) failed") }
        if let last = stats.lastDrainAt {
            parts.append("last drain \(Self.relativeAge(last))")
        }
        return parts.joined(separator: " · ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static func relativeAge(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// An `.accessory` app has no window to anchor an alert, so activate first.
    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Defaults reload -------------------------------------------------

    /// Install or remove the menu bar icon AND switch the activation policy.
    ///
    /// When the menu bar is hidden, switch to .regular so the app shows in
    /// the Dock and Force Quit — without that fallback the user has no GUI
    /// route to quit. When the menu bar is back, switch to .accessory to
    /// disappear from the Dock and Cmd-Tab again.
    private func applyMenuBarVisibility(_ enabled: Bool) {
        if enabled {
            menuBar.install()
            NSApp.setActivationPolicy(.accessory)
        } else {
            menuBar.uninstall()
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func cachePreferenceSnapshot() {
        snapMenuBarEnabled = prefs.menuBarEnabled
        snapHotkeyKeyCode  = prefs.hotkeyKeyCode
        snapHotkeyModifiers = prefs.hotkeyModifiers
        snapVoiceHotkeyKeyCode = prefs.voiceHotkeyKeyCode
        snapVoiceHotkeyModifiers = prefs.voiceHotkeyModifiers
        snapDestinationFolder = prefs.destinationFolder
    }

    @objc private func defaultsChanged(_ note: Notification) {
        reconcilePreferences()
    }

    /// Compare each preference against the cached snapshot and apply the
    /// runtime effect of anything that changed. Called both from
    /// didChangeNotification (in-process writes) and from the periodic poll
    /// (external `defaults write` from the CLI).
    private func reconcilePreferences() {
        let menuBar = prefs.menuBarEnabled
        if menuBar != snapMenuBarEnabled {
            snapMenuBarEnabled = menuBar
            applyMenuBarVisibility(menuBar)
        }

        let kc = prefs.hotkeyKeyCode
        let mods = prefs.hotkeyModifiers
        if kc != snapHotkeyKeyCode || mods != snapHotkeyModifiers {
            snapHotkeyKeyCode = kc
            snapHotkeyModifiers = mods
            hotkey.registerCapture(keyCode: kc, cocoaModifiers: mods)
        }

        let vkc = prefs.voiceHotkeyKeyCode
        let vmods = prefs.voiceHotkeyModifiers
        if vkc != snapVoiceHotkeyKeyCode || vmods != snapVoiceHotkeyModifiers {
            snapVoiceHotkeyKeyCode = vkc
            snapVoiceHotkeyModifiers = vmods
            hotkey.registerVoice(keyCode: vkc, cocoaModifiers: vmods)
        }

        let dest = prefs.destinationFolder
        if dest != snapDestinationFolder {
            snapDestinationFolder = dest
            _ = ContentHandler.ensureDirectory(prefs.destinationFolderURL)
        }
    }

    private func startDefaultsSyncTimer() {
        defaultsSyncTimer?.invalidate()
        let timer = Timer(timeInterval: defaultsSyncInterval, repeats: true) { [weak self] _ in
            self?.syncDefaultsFromDisk()
        }
        // Use .common so the poll keeps ticking during tracking-mode runs
        // (e.g. while the user is dragging the duration slider).
        RunLoop.main.add(timer, forMode: .common)
        defaultsSyncTimer = timer
    }

    private func syncDefaultsFromDisk() {
        // synchronize() is documented as deprecated for normal use because
        // UserDefaults usually auto-syncs in-process. For our purpose —
        // detecting out-of-process plist writes from `defaults write` — it
        // is still the documented mechanism and the only public API that
        // forces a re-read.
        UserDefaults.standard.synchronize()
        reconcilePreferences()
    }

    // MARK: - Hotkey ----------------------------------------------------------

    private func handleHotkey() {
        if isWindowVisible { return } // ignore second press while open
        // Capture frontmost app BEFORE showing our panel.
        pendingSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        captureWindow.captureView.sourceApp = pendingSourceApp
        isWindowVisible = true
        captureWindow.showCapture(at: prefs.windowPosition)
    }

    private func dismissWindow(saved: Bool) {
        guard isWindowVisible else { return }
        let finalize = { [weak self] in
            guard let self = self else { return }
            self.captureWindow.dismissCapture()
            self.isWindowVisible = false
            self.pendingSourceApp = nil
        }
        if saved && prefs.confirmationEnabled {
            captureWindow.showConfirmation(durationMs: prefs.confirmationDuration) {
                finalize()
            }
        } else {
            finalize()
        }
    }

    // MARK: - Submission ------------------------------------------------------

    private func handleSubmit(_ payload: CapturePayload) {
        var enriched = payload
        if enriched.sourceApp == nil { enriched.sourceApp = pendingSourceApp }

        // Validate destination
        let destination = prefs.destinationFolderURL
        if !ContentHandler.ensureDirectory(destination) {
            // Folder missing/unwritable: show the picker, then retry once.
            chooseFolderInteractive { [weak self] newURL in
                guard let self = self, let newURL = newURL else {
                    self?.dismissWindow(saved: false)
                    return
                }
                self.prefs.destinationFolder = newURL.path
                _ = ContentHandler.ensureDirectory(newURL)
                let result = self.saveAndPublish(enriched, to: newURL)
                self.handleResult(result)
            }
            return
        }

        let result = saveAndPublish(enriched, to: destination)
        handleResult(result)
    }

    /// Save a local capture into the vault and, on success, also publish it to
    /// the relay (best-effort, M5). The local write is the system of record.
    private func saveAndPublish(_ payload: CapturePayload, to destination: URL) -> CaptureResult {
        let result = ContentHandler.save(payload, to: destination, prefs: prefs)
        if case .saved = result { publishToRelay(payload) }
        return result
    }

    private func publishToRelay(_ payload: CapturePayload) {
        let now = Date()
        let trimmed = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            relayProducer.publishText(payload.text, sourceApp: payload.sourceApp, capturedAt: now)
        } else if let image = payload.pastedImageData {
            relayProducer.publishImage(image, capturedAt: now)
        } else if let fileURL = payload.pastedFileURL {
            // Read lazily; skip very large files (the local copy is authoritative).
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64 ?? 0
            if size <= 50 * 1024 * 1024, let data = try? Data(contentsOf: fileURL) {
                relayProducer.publishFile(data, filename: fileURL.lastPathComponent, capturedAt: now)
            }
        }
    }

    private func handleResult(_ result: CaptureResult) {
        switch result {
        case .saved:
            dismissWindow(saved: true)
        case .empty:
            dismissWindow(saved: false)
        case .fileTooLarge:
            captureWindow.captureView.showWarning("File over 100MB — type a note instead.")
        case .destinationMissing:
            // Already attempted to recover above; just dismiss silently.
            dismissWindow(saved: false)
        case .error:
            dismissWindow(saved: false)
        }
    }

    private func chooseFolderInteractive(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose destination folder"
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    // MARK: - Preferences -----------------------------------------------------

    private func showPreferences() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
            preferencesController?.onHotkeyChanged = { [weak self] kc, mods in
                self?.hotkey.registerCapture(keyCode: kc, cocoaModifiers: mods)
            }
            preferencesController?.onVoiceHotkeyChanged = { [weak self] kc, mods in
                self?.hotkey.registerVoice(keyCode: kc, cocoaModifiers: mods)
            }
            preferencesController?.onMenuBarChanged = { [weak self] enabled in
                self?.applyMenuBarVisibility(enabled)
            }
            preferencesController?.onLinkDevice = { [weak self] in
                self?.linkADevice()
            }
            preferencesController?.relayStatusText = { [weak self] in
                self?.composeRelayStatusLine() ?? ""
            }
            // Unregister BOTH chords while a field is capturing so the user can
            // (re)bind a combination that overlaps either one — otherwise the
            // Carbon hotkey would swallow the keypress before the field sees it.
            preferencesController?.onHotkeyCaptureBegin = { [weak self] in
                self?.hotkey.unregisterAll()
            }
            preferencesController?.onHotkeyCaptureEnd = { [weak self] in
                guard let self = self else { return }
                self.hotkey.registerCapture(keyCode: self.prefs.hotkeyKeyCode,
                                            cocoaModifiers: self.prefs.hotkeyModifiers)
                self.hotkey.registerVoice(keyCode: self.prefs.voiceHotkeyKeyCode,
                                          cocoaModifiers: self.prefs.voiceHotkeyModifiers)
            }
        }
        preferencesController?.show()
    }
}

