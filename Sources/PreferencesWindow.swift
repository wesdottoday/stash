import AppKit

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    var onHotkeyChanged: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    var onMenuBarChanged: ((Bool) -> Void)?
    var onHotkeyCaptureBegin: (() -> Void)?
    var onHotkeyCaptureEnd: (() -> Void)?

    private let prefs = Preferences.shared
    private let folderField = NSTextField(string: "")
    private let chooseFolderButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let hotkeyField = KeyCaptureField()
    private let confirmToggle = NSButton(checkboxWithTitle: "Show save confirmation", target: nil, action: nil)
    private let durationField = NSTextField(string: "100")
    private let durationStepper = NSStepper()
    private let normalizationToggle = NSButton(checkboxWithTitle: "Image normalization", target: nil, action: nil)
    private let menuBarToggle = NSButton(checkboxWithTitle: "Show menu bar icon", target: nil, action: nil)
    private let menuBarNoteHeader = NSTextField(labelWithString: "")
    private let menuBarNoteCode = NSTextField(labelWithString: "")
    private let menuBarNoteDocsLink = NSButton(title: "", target: nil, action: nil)
    private lazy var menuBarNoteContainer: NSStackView = {
        let s = NSStackView(views: [menuBarNoteHeader, menuBarNoteCode, menuBarNoteDocsLink])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        return s
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
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

        confirmToggle.target = self
        confirmToggle.action = #selector(confirmToggleChanged)
        durationField.target = self
        durationField.action = #selector(durationFieldChanged)
        durationField.alignment = .right
        durationField.placeholderString = "100"
        durationField.formatter = makeIntegerFormatter(min: 50, max: 500)

        durationStepper.minValue = 50
        durationStepper.maxValue = 500
        durationStepper.increment = 10
        durationStepper.valueWraps = false
        durationStepper.target = self
        durationStepper.action = #selector(durationStepperChanged)

        normalizationToggle.target = self
        normalizationToggle.action = #selector(normalizationChanged)

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

        let durationRow = horizontalStack([durationField, durationStepper, label("ms")], spacing: 6)
        let confirmRow = labeledRow("Save confirmation:",
                                    control: verticalStack([confirmToggle, durationRow], spacing: 6))

        let imageRow = labeledRow("Image handling:", control: normalizationToggle)
        let menuBarRow = labeledRow("Menu bar icon:", control: verticalStack([menuBarToggle, menuBarNoteContainer], spacing: 4))

        let footer = makeFooter()

        let separator = NSBox()
        separator.boxType = .separator

        let stack = verticalStack(
            [folderRow, hotkeyRow, confirmRow, imageRow, menuBarRow, separator, footer],
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
            durationField.widthAnchor.constraint(equalToConstant: 70),
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

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 12)
        return l
    }

    private func makeIntegerFormatter(min: Int, max: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = NSNumber(value: min)
        f.maximum = NSNumber(value: max)
        f.maximumFractionDigits = 0
        return f
    }

    // MARK: - Load / Save ----------------------------------------------------

    private func loadFromPreferences() {
        folderField.stringValue = (prefs.destinationFolder as NSString).abbreviatingWithTildeInPath
        hotkeyField.setBinding(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
        confirmToggle.state = prefs.confirmationEnabled ? .on : .off
        durationField.stringValue = String(prefs.confirmationDuration)
        durationStepper.integerValue = prefs.confirmationDuration
        durationField.isEnabled = prefs.confirmationEnabled
        durationStepper.isEnabled = prefs.confirmationEnabled
        normalizationToggle.state = prefs.imageNormalization ? .on : .off
        menuBarToggle.state = prefs.menuBarEnabled ? .on : .off
        updateMenuBarNote()
    }

    private func updateMenuBarNote() {
        let visible = !prefs.menuBarEnabled
        menuBarNoteHeader.stringValue = visible ? "Hidden. Re-enable via the command line:" : ""
        menuBarNoteCode.stringValue   = visible ? "defaults write com.wesdottoday.stash menuBarEnabled -bool true" : ""
        menuBarNoteHeader.isHidden = !visible
        menuBarNoteCode.isHidden   = !visible
        menuBarNoteDocsLink.isHidden = !visible
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
        prefs.confirmationEnabled = (confirmToggle.state == .on)
        durationField.isEnabled = prefs.confirmationEnabled
        durationStepper.isEnabled = prefs.confirmationEnabled
    }

    @objc private func durationFieldChanged() {
        let v = max(50, min(500, durationField.integerValue))
        prefs.confirmationDuration = v
        durationField.integerValue = v
        durationStepper.integerValue = v
    }

    @objc private func durationStepperChanged() {
        let v = max(50, min(500, durationStepper.integerValue))
        prefs.confirmationDuration = v
        durationField.integerValue = v
    }

    @objc private func normalizationChanged() {
        prefs.imageNormalization = (normalizationToggle.state == .on)
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
        // No-op for now
    }
}
