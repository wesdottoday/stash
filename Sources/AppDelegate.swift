import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private var captureWindow: CaptureWindow!
    private var hotkey: HotkeyManager!
    private var menuBar: MenuBarController!
    private var preferencesController: PreferencesWindowController?

    private var isWindowVisible = false
    private var pendingSourceApp: String?

    // Snapshot of the last-applied preference values, so we can tell which
    // keys actually changed when UserDefaults.didChangeNotification fires.
    private var snapMenuBarEnabled: Bool = true
    private var snapHotkeyKeyCode: UInt32 = 0
    private var snapHotkeyModifiers: NSEvent.ModifierFlags = []
    private var snapDestinationFolder: String = ""

    // Periodic sync so out-of-process `defaults write` from the CLI is
    // picked up — UserDefaults' in-memory cache doesn't always notice when
    // the plist is rewritten beneath us, so didChangeNotification alone is
    // insufficient.
    private var defaultsSyncTimer: Timer?
    private let defaultsSyncInterval: TimeInterval = 2.0

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

        // Hotkey
        hotkey = HotkeyManager()
        hotkey.onHotkey = { [weak self] in self?.handleHotkey() }
        hotkey.register(keyCode: prefs.hotkeyKeyCode, cocoaModifiers: prefs.hotkeyModifiers)

        // Reapply registrations when the system wakes from sleep.
        let wsNC = NSWorkspace.shared.notificationCenter
        wsNC.addObserver(forName: NSWorkspace.didWakeNotification,
                         object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.hotkey.register(keyCode: self.prefs.hotkeyKeyCode,
                                 cocoaModifiers: self.prefs.hotkeyModifiers)
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

        // First launch: show preferences.
        if !prefs.hasLaunchedBefore {
            prefs.hasLaunchedBefore = true
            showPreferences()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        defaultsSyncTimer?.invalidate()
        defaultsSyncTimer = nil
        hotkey?.unregister()
        menuBar?.uninstall()
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
            hotkey.register(keyCode: kc, cocoaModifiers: mods)
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
                let result = ContentHandler.save(enriched, to: newURL, prefs: self.prefs)
                self.handleResult(result)
            }
            return
        }

        let result = ContentHandler.save(enriched, to: destination, prefs: prefs)
        handleResult(result)
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
                self?.hotkey.register(keyCode: kc, cocoaModifiers: mods)
            }
            preferencesController?.onMenuBarChanged = { [weak self] enabled in
                self?.applyMenuBarVisibility(enabled)
            }
            preferencesController?.onHotkeyCaptureBegin = { [weak self] in
                self?.hotkey.unregister()
            }
            preferencesController?.onHotkeyCaptureEnd = { [weak self] in
                guard let self = self else { return }
                self.hotkey.register(keyCode: self.prefs.hotkeyKeyCode,
                                     cocoaModifiers: self.prefs.hotkeyModifiers)
            }
        }
        preferencesController?.show()
    }
}

