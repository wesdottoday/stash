import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private var captureWindow: CaptureWindow!
    private var hotkey: HotkeyManager!
    private var menuBar: MenuBarController!
    private var preferencesController: PreferencesWindowController?

    private var isWindowVisible = false
    private var pendingSourceApp: String?

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
        if prefs.menuBarEnabled { menuBar.install() }

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

        // First launch: show preferences.
        if !prefs.hasLaunchedBefore {
            prefs.hasLaunchedBefore = true
            showPreferences()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.unregister()
        menuBar?.uninstall()
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
                guard let self = self else { return }
                if enabled { self.menuBar.install() } else { self.menuBar.uninstall() }
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

