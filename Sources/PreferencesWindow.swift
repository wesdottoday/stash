import AppKit

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    var onHotkeyChanged: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    var onVoiceHotkeyChanged: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    var onMenuBarChanged: ((Bool) -> Void)?
    var onHotkeyCaptureBegin: (() -> Void)?
    var onHotkeyCaptureEnd: (() -> Void)?
    var onLinkDevice: (() -> Void)?
    /// Provides a live one-line relay/consumer status (connection, waiting, drain age).
    var relayStatusText: (() -> String)?

    private let prefs = Preferences.shared
    private let folderField = NSTextField(string: "")
    private let chooseFolderButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let hotkeyField = KeyCaptureField()
    private let voiceHotkeyField = KeyCaptureField()
    private var statusTimer: Timer?
    private let confirmToggle = NSButton(checkboxWithTitle: "Show save confirmation", target: nil, action: nil)
    private let durationSlider = NSSlider()
    private let durationValueLabel = NSTextField(labelWithString: "100 ms")
    private let normalizationToggle = NSButton(checkboxWithTitle: "Image normalization", target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let relayStatusLabel = NSTextField(labelWithString: "")
    private let linkDeviceButton = NSButton(title: "Link a device…", target: nil, action: nil)
    private let menuBarToggle = NSButton(checkboxWithTitle: "Show menu bar icon", target: nil, action: nil)
    private let menuBarNoteHeader = NSTextField(labelWithString: "")
    private let menuBarNoteCode = NSTextField(labelWithString: "")
    private let menuBarNoteCopyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let menuBarNoteDocsLink = NSButton(title: "", target: nil, action: nil)
    private lazy var menuBarNoteCodeRow: NSStackView = {
        let s = NSStackView(views: [menuBarNoteCode, menuBarNoteCopyButton])
        s.orientation = .horizontal
        s.alignment = .firstBaseline
        s.spacing = 6
        return s
    }()
    private lazy var menuBarNoteContainer: NSStackView = {
        let s = NSStackView(views: [menuBarNoteHeader, menuBarNoteCodeRow, menuBarNoteDocsLink])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        return s
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 490),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "stash Preferences"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildLayout()
        loadFromPreferences()
    }

    func show() {
        // Always reload from defaults on show so external changes via
        // `defaults write` are reflected in the UI.
        loadFromPreferences()
        if let w = window {
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        startStatusTimer()
    }

    /// While the window is open, refresh the live relay status line every 2s.
    private func startStatusTimer() {
        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshRelayStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    // MARK: - Layout ----------------------------------------------------------

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        // Folder row
        folderField.isBordered = true
        folderField.bezelStyle = .roundedBezel
        folderField.isEditable = true
        folderField.usesSingleLineMode = true
        folderField.lineBreakMode = .byTruncatingHead
        folderField.target = self
        folderField.action = #selector(folderFieldChanged)

        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder)
        chooseFolderButton.bezelStyle = .rounded

        hotkeyField.onCapture = { [weak self] kc, mods in
            self?.prefs.hotkeyKeyCode = kc
            self?.prefs.hotkeyModifiers = mods
            self?.onHotkeyChanged?(kc, mods)
        }
        hotkeyField.onWillBeginCapture = { [weak self] in
            self?.onHotkeyCaptureBegin?()
        }
        hotkeyField.onDidEndCapture = { [weak self] in
            self?.onHotkeyCaptureEnd?()
        }

        voiceHotkeyField.onCapture = { [weak self] kc, mods in
            self?.prefs.voiceHotkeyKeyCode = kc
            self?.prefs.voiceHotkeyModifiers = mods
            self?.onVoiceHotkeyChanged?(kc, mods)
        }
        voiceHotkeyField.onWillBeginCapture = { [weak self] in
            self?.onHotkeyCaptureBegin?()
        }
        voiceHotkeyField.onDidEndCapture = { [weak self] in
            self?.onHotkeyCaptureEnd?()
        }

        confirmToggle.target = self
        confirmToggle.action = #selector(confirmToggleChanged)

        let range = Preferences.confirmationDurationRange
        durationSlider.minValue = Double(range.lowerBound)
        durationSlider.maxValue = Double(range.upperBound)
        durationSlider.isContinuous = true
        durationSlider.allowsTickMarkValuesOnly = false
        durationSlider.target = self
        durationSlider.action = #selector(durationSliderChanged)
        durationSlider.controlSize = .small

        durationValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationValueLabel.textColor = .secondaryLabelColor
        durationValueLabel.alignment = .right

        normalizationToggle.target = self
        normalizationToggle.action = #selector(normalizationChanged)

        relayStatusLabel.font = .systemFont(ofSize: 12)
        relayStatusLabel.textColor = .secondaryLabelColor
        relayStatusLabel.usesSingleLineMode = false
        relayStatusLabel.maximumNumberOfLines = 3
        relayStatusLabel.lineBreakMode = .byTruncatingTail

        linkDeviceButton.bezelStyle = .rounded
        linkDeviceButton.controlSize = .regular
        linkDeviceButton.target = self
        linkDeviceButton.action = #selector(linkDeviceClicked)

        loginToggle.target = self
        loginToggle.action = #selector(loginToggleChanged)

        menuBarToggle.target = self
        menuBarToggle.action = #selector(menuBarChanged)

        menuBarNoteHeader.font = .systemFont(ofSize: 11)
        menuBarNoteHeader.textColor = .secondaryLabelColor
        menuBarNoteHeader.usesSingleLineMode = false
        menuBarNoteHeader.maximumNumberOfLines = 2

        menuBarNoteCode.font = .userFixedPitchFont(ofSize: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        menuBarNoteCode.textColor = .secondaryLabelColor
        menuBarNoteCode.usesSingleLineMode = true
        menuBarNoteCode.lineBreakMode = .byTruncatingTail
        // Allow click-drag selection and Cmd-C so the user can lift the
        // command line out of the prefs pane without retyping it.
        menuBarNoteCode.isSelectable = true
        menuBarNoteCode.allowsEditingTextAttributes = false

        menuBarNoteCopyButton.controlSize = .small
        menuBarNoteCopyButton.bezelStyle = .rounded
        menuBarNoteCopyButton.font = .systemFont(ofSize: 11)
        menuBarNoteCopyButton.target = self
        menuBarNoteCopyButton.action = #selector(copyMenuBarHintCommand)

        menuBarNoteDocsLink.target = self
        menuBarNoteDocsLink.action = #selector(openSourceLink)
        menuBarNoteDocsLink.isBordered = false
        menuBarNoteDocsLink.bezelStyle = .recessed
        menuBarNoteDocsLink.font = .systemFont(ofSize: 11)
        menuBarNoteDocsLink.attributedTitle = NSAttributedString(
            string: "Docs: github.com/wesdottoday/stash",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: 11),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        menuBarNoteDocsLink.setButtonType(.momentaryChange)
        if let cell = menuBarNoteDocsLink.cell as? NSButtonCell {
            cell.imagePosition = .noImage
            cell.bezelStyle = .recessed
        }

        let folderRow = labeledRow(
            "Destination folder:",
            control: horizontalStack([folderField, chooseFolderButton], spacing: 8)
        )
        folderField.translatesAutoresizingMaskIntoConstraints = false
        folderField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        folderField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let hotkeyRow = labeledRow("Global hotkey:", control: hotkeyField)
        let voiceHotkeyRow = labeledRow("Voice hotkey:", control: voiceHotkeyField)

        let durationRow = horizontalStack([durationSlider, durationValueLabel], spacing: 8)
        durationSlider.translatesAutoresizingMaskIntoConstraints = false
        durationSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        durationValueLabel.translatesAutoresizingMaskIntoConstraints = false
        durationValueLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let confirmRow = labeledRow("Save confirmation:",
                                    control: verticalStack([confirmToggle, durationRow], spacing: 6))

        let imageRow = labeledRow("Image handling:", control: normalizationToggle)
        let syncRow = labeledRow("Sync:", control: verticalStack([relayStatusLabel, linkDeviceButton], spacing: 6))
        let menuBarRow = labeledRow("Menu bar icon:", control: verticalStack([menuBarToggle, menuBarNoteContainer], spacing: 4))
        let loginRow = labeledRow("Login:", control: loginToggle)

        let footer = makeFooter()

        let separator = NSBox()
        separator.boxType = .separator

        let stack = verticalStack(
            [folderRow, hotkeyRow, voiceHotkeyRow, confirmRow, imageRow, syncRow, menuBarRow, loginRow, separator, footer],
            spacing: 14
        )
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            folderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            hotkeyField.widthAnchor.constraint(equalToConstant: 160),
            voiceHotkeyField.widthAnchor.constraint(equalToConstant: 160),
        ])
    }

    private func makeFooter() -> NSView {
        let line = NSTextField(labelWithString: "We don't collect any data.")
        line.textColor = .secondaryLabelColor
        line.font = .systemFont(ofSize: 11)

        let link = NSButton(title: "source", target: self, action: #selector(openSourceLink))
        link.isBordered = false
        link.bezelStyle = .recessed
        link.font = .systemFont(ofSize: 11)
        link.contentTintColor = .linkColor
        if let title = link.attributedTitle.mutableCopy() as? NSMutableAttributedString {
            title.addAttribute(.foregroundColor, value: NSColor.linkColor, range: NSRange(location: 0, length: title.length))
            link.attributedTitle = title
        }

        return horizontalStack([line, link], spacing: 6)
    }

    private func labeledRow(_ caption: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.alignment = .right
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .firstBaseline
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    // MARK: - Load / Save ----------------------------------------------------

    private func loadFromPreferences() {
        folderField.stringValue = (prefs.destinationFolder as NSString).abbreviatingWithTildeInPath
        hotkeyField.setBinding(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
        voiceHotkeyField.setBinding(keyCode: prefs.voiceHotkeyKeyCode, modifiers: prefs.voiceHotkeyModifiers)
        confirmToggle.state = prefs.confirmationEnabled ? .on : .off
        durationSlider.integerValue = prefs.confirmationDuration
        durationValueLabel.stringValue = "\(prefs.confirmationDuration) ms"
        durationSlider.isEnabled = prefs.confirmationEnabled
        durationValueLabel.alphaValue = prefs.confirmationEnabled ? 1.0 : 0.4
        normalizationToggle.state = prefs.imageNormalization ? .on : .off
        menuBarToggle.state = prefs.menuBarEnabled ? .on : .off
        loginToggle.state = prefs.startAtLogin ? .on : .off
        updateMenuBarNote()
        refreshRelayStatus()
    }

    /// Update the Sync row from the current enrollment state. Public so the
    /// AppDelegate can refresh it after a deep-link enrollment completes.
    func refreshRelayStatus() {
        if let base = prefs.relayBaseURL, let url = URL(string: base),
           let deviceId = (try? RelayCredentials.deviceId()) ?? nil {
            let host = url.host ?? base
            let shortID = String(deviceId.prefix(8))
            var line = "Enrolled with \(host) · \(shortID)…"
            if let status = relayStatusText?(), !status.isEmpty { line += "\n\(status)" }
            relayStatusLabel.stringValue = line
            relayStatusLabel.textColor = .secondaryLabelColor
            linkDeviceButton.isEnabled = true
        } else {
            relayStatusLabel.stringValue = "Not enrolled. Run `stash-relay enroll` and open the link, or scan from another device."
            relayStatusLabel.textColor = .tertiaryLabelColor
            linkDeviceButton.isEnabled = false
        }
    }

    private func updateMenuBarNote() {
        let visible = !prefs.menuBarEnabled
        menuBarNoteHeader.stringValue = visible ? "Hidden. Re-enable via the command line:" : ""
        menuBarNoteCode.stringValue   = visible ? Self.menuBarHintCommand : ""
        menuBarNoteHeader.isHidden = !visible
        menuBarNoteCodeRow.isHidden = !visible
        menuBarNoteCode.isHidden   = !visible
        menuBarNoteCopyButton.isHidden = !visible
        menuBarNoteDocsLink.isHidden = !visible
    }

    private static let menuBarHintCommand = "defaults write com.wesdottoday.stash menuBarEnabled -bool true"

    @objc private func copyMenuBarHintCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.menuBarHintCommand, forType: .string)
        // Tiny visual ack — flip the title for a moment so the user knows it
        // worked, since the pasteboard is otherwise invisible.
        menuBarNoteCopyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            self?.menuBarNoteCopyButton.title = "Copy"
        }
    }

    // MARK: - Actions ---------------------------------------------------------

    @objc private func folderFieldChanged() {
        let expanded = (folderField.stringValue as NSString).expandingTildeInPath
        prefs.destinationFolder = expanded
        _ = ContentHandler.ensureDirectory(URL(fileURLWithPath: expanded, isDirectory: true))
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose destination folder"
        panel.prompt = "Choose"
        let current = URL(fileURLWithPath: prefs.destinationFolder, isDirectory: true)
        panel.directoryURL = current
        if panel.runModal() == .OK, let url = panel.url {
            prefs.destinationFolder = url.path
            folderField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            _ = ContentHandler.ensureDirectory(url)
        }
    }

    @objc private func confirmToggleChanged() {
        let enabled = (confirmToggle.state == .on)
        prefs.confirmationEnabled = enabled
        durationSlider.isEnabled = enabled
        durationValueLabel.alphaValue = enabled ? 1.0 : 0.4
    }

    @objc private func durationSliderChanged() {
        // Round to nearest 10 ms while dragging for less jitter on the label.
        let raw = durationSlider.integerValue
        let snapped = ((raw + 5) / 10) * 10
        prefs.confirmationDuration = snapped
        durationValueLabel.stringValue = "\(snapped) ms"
    }

    @objc private func normalizationChanged() {
        prefs.imageNormalization = (normalizationToggle.state == .on)
    }

    @objc private func linkDeviceClicked() {
        onLinkDevice?()
    }

    @objc private func loginToggleChanged() {
        prefs.startAtLogin = (loginToggle.state == .on)
    }

    @objc private func menuBarChanged() {
        let enabled = (menuBarToggle.state == .on)
        prefs.menuBarEnabled = enabled
        onMenuBarChanged?(enabled)
        updateMenuBarNote()
    }

    @objc private func openSourceLink() {
        if let url = URL(string: "https://github.com/wesdottoday/stash") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Window delegate -------------------------------------------------

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
    }
}
