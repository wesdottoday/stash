import AppKit

final class CaptureView: NSView, NSTextViewDelegate {
    // MARK: - Public callbacks
    var onSubmitPayload: ((CapturePayload) -> Void)?
    var onCancel: (() -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)?

    var firstResponderTarget: NSResponder? { textView }

    // MARK: - Layout constants
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 12
    private let imagePreviewMaxHeight: CGFloat = 120
    private let imagePreviewSpacing: CGFloat = 8
    private let lineHeightHint: CGFloat = 22 // font + line gap
    private let minLines = 1
    private let maxLines = 6
    private let warningHeight: CGFloat = 22
    private let warningSpacing: CGFloat = 8

    // MARK: - Subviews
    private let visualEffect = NSVisualEffectView()
    private let imagePreview = NSImageView()
    private let attachmentChip = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    let textView = CaptureTextView()
    private let hintLabel = NSTextField(labelWithString: "↵ to save.")
    private let confirmationLabel = NSTextField(labelWithString: "✓")
    private let warningLabel = NSTextField(labelWithString: "")

    // MARK: - State
    private var pastedImageData: Data?
    private var pastedFileURL: URL?
    private var hasUserInteraction = false
    private var imageVisible = false
    private var attachmentChipVisible = false
    private var warningVisible = false
    private let attachmentChipHeight: CGFloat = 22
    private let attachmentChipSpacing: CGFloat = 6

    var sourceApp: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupSubviews()
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Setup -----------------------------------------------------------

    private func setupSubviews() {
        // Background blur, rounded
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffect)

        NSLayoutConstraint.activate([
            visualEffect.topAnchor.constraint(equalTo: topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Image preview
        imagePreview.imageScaling = .scaleProportionallyDown
        imagePreview.imageAlignment = .alignLeft
        imagePreview.isHidden = true
        imagePreview.wantsLayer = true
        imagePreview.layer?.cornerRadius = 4

        // Scroll view + text view
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none

        textView.font = NSFont.systemFont(ofSize: 16)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        textView.onPasteRequest = { [weak self] in
            self?.handlePaste() ?? false
        }
        scrollView.documentView = textView

        // Hint
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.isEditable = false
        hintLabel.isBordered = false
        hintLabel.drawsBackground = false
        hintLabel.backgroundColor = .clear
        hintLabel.alignment = .right
        hintLabel.usesSingleLineMode = true

        // Confirmation
        confirmationLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        confirmationLabel.textColor = .systemGreen
        confirmationLabel.isEditable = false
        confirmationLabel.isBordered = false
        confirmationLabel.drawsBackground = false
        confirmationLabel.alignment = .right
        confirmationLabel.alphaValue = 0

        // Warning
        warningLabel.font = .systemFont(ofSize: 12)
        warningLabel.textColor = .systemRed
        warningLabel.isEditable = false
        warningLabel.isBordered = false
        warningLabel.drawsBackground = false
        warningLabel.usesSingleLineMode = false
        warningLabel.alignment = .left
        warningLabel.isHidden = true

        // Attachment chip — shows filename/size when a file is pasted
        attachmentChip.font = .systemFont(ofSize: 12, weight: .medium)
        attachmentChip.textColor = .secondaryLabelColor
        attachmentChip.isEditable = false
        attachmentChip.isBordered = false
        attachmentChip.drawsBackground = false
        attachmentChip.usesSingleLineMode = true
        attachmentChip.lineBreakMode = .byTruncatingMiddle
        attachmentChip.isHidden = true

        addSubview(imagePreview)
        addSubview(attachmentChip)
        addSubview(scrollView)
        addSubview(hintLabel)
        addSubview(confirmationLabel)
        addSubview(warningLabel)
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        let contentLeft = bounds.minX + horizontalPadding
        let contentRight = bounds.maxX - horizontalPadding
        let contentWidth = contentRight - contentLeft
        let contentTop = bounds.maxY - verticalPadding
        let contentBottom = bounds.minY + verticalPadding

        var cursorY = contentTop

        // Image preview (top)
        if imageVisible, let img = imagePreview.image {
            let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
            let maxW = contentWidth
            var w = min(maxW, img.size.width)
            var h = w / max(aspect, 0.0001)
            if h > imagePreviewMaxHeight {
                h = imagePreviewMaxHeight
                w = h * aspect
            }
            imagePreview.frame = NSRect(x: contentLeft, y: cursorY - h, width: w, height: h)
            cursorY -= (h + imagePreviewSpacing)
        }

        // Attachment chip (above text field, under image preview if any)
        if attachmentChipVisible {
            attachmentChip.frame = NSRect(x: contentLeft, y: cursorY - attachmentChipHeight,
                                          width: contentWidth, height: attachmentChipHeight)
            cursorY -= (attachmentChipHeight + attachmentChipSpacing)
        }

        // Warning (just under image preview, above text field)
        if warningVisible {
            warningLabel.frame = NSRect(x: contentLeft, y: cursorY - warningHeight,
                                        width: contentWidth, height: warningHeight)
            cursorY -= (warningHeight + warningSpacing)
        }

        let textHeight = max(cursorY - contentBottom, lineHeightHint)
        scrollView.frame = NSRect(x: contentLeft, y: contentBottom,
                                  width: contentWidth, height: textHeight)

        let hintSize = hintLabel.intrinsicContentSize
        hintLabel.frame = NSRect(
            x: contentRight - hintSize.width,
            y: contentBottom + max(0, (textHeight - hintSize.height) / 2),
            width: hintSize.width,
            height: hintSize.height
        )
        let confSize = confirmationLabel.intrinsicContentSize
        confirmationLabel.frame = NSRect(
            x: contentRight - confSize.width,
            y: contentBottom + max(0, (textHeight - confSize.height) / 2),
            width: confSize.width,
            height: confSize.height
        )
    }

    // MARK: - Lifecycle -------------------------------------------------------

    func prepareForShow() {
        resetState()
        hintLabel.isHidden = false
        confirmationLabel.alphaValue = 0
    }

    func resetState() {
        textView.string = ""
        pastedImageData = nil
        pastedFileURL = nil
        hasUserInteraction = false
        imagePreview.image = nil
        imagePreview.isHidden = true
        imageVisible = false
        attachmentChip.stringValue = ""
        attachmentChip.isHidden = true
        attachmentChipVisible = false
        warningLabel.stringValue = ""
        warningLabel.isHidden = true
        warningVisible = false
        confirmationLabel.alphaValue = 0
        hintLabel.isHidden = false
        needsLayout = true
    }

    // MARK: - Height ----------------------------------------------------------

    func preferredHeight() -> CGFloat {
        let lc = textView.layoutManager
        let tc = textView.textContainer
        var contentHeight: CGFloat = lineHeightHint
        if let lc = lc, let tc = tc {
            lc.ensureLayout(for: tc)
            let used = lc.usedRect(for: tc).height
            let lines = max(CGFloat(minLines), min(CGFloat(maxLines), ceil(used / lineHeightHint)))
            contentHeight = max(lineHeightHint * lines, used)
            // Enable internal scrolling if past max
            scrollView.hasVerticalScroller = used > lineHeightHint * CGFloat(maxLines)
            if used > lineHeightHint * CGFloat(maxLines) {
                contentHeight = lineHeightHint * CGFloat(maxLines)
            }
        }
        var total = contentHeight + verticalPadding * 2
        if imageVisible, let img = imagePreview.image {
            let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
            let maxW = bounds.width - horizontalPadding * 2
            var w = min(maxW, img.size.width)
            var h = w / max(aspect, 0.0001)
            if h > imagePreviewMaxHeight {
                h = imagePreviewMaxHeight
                w = h * aspect
            }
            _ = w
            total += h + imagePreviewSpacing
        }
        if attachmentChipVisible {
            total += attachmentChipHeight + attachmentChipSpacing
        }
        if warningVisible {
            total += warningHeight + warningSpacing
        }
        return total
    }

    // MARK: - Submit ----------------------------------------------------------

    private func submit() {
        let payload = CapturePayload(text: textView.string,
                                     pastedImageData: pastedImageData,
                                     pastedFileURL: pastedFileURL,
                                     sourceApp: sourceApp)
        onSubmitPayload?(payload)
    }

    // MARK: - Confirmation ----------------------------------------------------

    func showConfirmationIndicator() {
        hintLabel.isHidden = true
        confirmationLabel.alphaValue = 1
    }

    func hideConfirmationIndicator() {
        confirmationLabel.alphaValue = 0
    }

    // MARK: - Warnings --------------------------------------------------------

    func showWarning(_ text: String) {
        warningLabel.stringValue = text
        warningLabel.isHidden = false
        warningVisible = true
        needsLayout = true
        onContentHeightChange?(preferredHeight())
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, self.warningLabel.stringValue == text else { return }
            self.hideWarning()
        }
    }

    func hideWarning() {
        warningLabel.isHidden = true
        warningVisible = false
        needsLayout = true
        onContentHeightChange?(preferredHeight())
    }

    // MARK: - Attachment chip -------------------------------------------------

    private func showAttachmentChip(label: String) {
        attachmentChip.stringValue = label
        attachmentChip.isHidden = false
        attachmentChipVisible = true
        needsLayout = true
    }

    private static let fileSizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    private func humanFileSize(_ size: Int64) -> String {
        Self.fileSizeFormatter.string(fromByteCount: size)
    }

    // MARK: - Paste -----------------------------------------------------------

    /// Returns true if paste was consumed (image or file). False to let the
    /// text view perform its normal paste.
    private func handlePaste() -> Bool {
        let pb = NSPasteboard.general

        // File URL on the clipboard → file paste (no image preview, copied as file)
        if let firstURL = filesFromPasteboard(pb).first {
            let attrs = try? FileManager.default.attributesOfItem(atPath: firstURL.path)
            let size = attrs?[.size] as? Int64 ?? 0
            if size > 100 * 1024 * 1024 {
                showWarning("File over 100MB — paste discarded. Type a note instead.")
                return true
            }
            pastedFileURL = firstURL
            showAttachmentChip(label: "📎 \(firstURL.lastPathComponent)" +
                               (size > 0 ? "  · \(humanFileSize(size))" : ""))
            hasUserInteraction = true
            hintLabel.isHidden = true
            needsLayout = true
            onContentHeightChange?(preferredHeight())
            return true
        }

        // Raw image data on the clipboard → image paste (with inline preview)
        if let (data, img) = imageFromPasteboard(pb) {
            pastedImageData = data
            imagePreview.image = img
            imagePreview.isHidden = false
            imageVisible = true
            hasUserInteraction = true
            hintLabel.isHidden = true
            needsLayout = true
            onContentHeightChange?(preferredHeight())
            return true
        }

        // Otherwise let the text view paste text normally
        return false
    }

    /// Read file URLs from the pasteboard, trying every shape Finder /
    /// command-line / drag-and-drop sources use in practice.
    private func filesFromPasteboard(_ pb: NSPasteboard) -> [URL] {
        // Modern API, file-only filter
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        // Modern API without filter, post-filter to file URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let filtered = urls.filter { $0.isFileURL }
            if !filtered.isEmpty { return filtered }
        }
        // public.file-url on each pasteboard item
        var collected: [URL] = []
        for item in pb.pasteboardItems ?? [] {
            if let s = item.string(forType: .fileURL),
               let url = URL(string: s), url.isFileURL {
                collected.append(url)
            }
        }
        if !collected.isEmpty { return collected }
        // Legacy NSFilenamesPboardType
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let names = pb.propertyList(forType: legacy) as? [String], !names.isEmpty {
            return names.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    /// Read an image off the pasteboard. Tries explicit data types first
    /// (so we preserve the original encoding for normalization decisions),
    /// then falls back to `NSImage(pasteboard:)` for everything else.
    private func imageFromPasteboard(_ pb: NSPasteboard) -> (data: Data, image: NSImage)? {
        // Explicit data types we want to preserve verbatim
        let explicitTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for t in explicitTypes {
            if let data = pb.data(forType: t), let img = NSImage(data: data) {
                return (data, img)
            }
        }
        // Walk every pasteboard item looking for an image-shaped UTI
        for item in pb.pasteboardItems ?? [] {
            for type in item.types {
                let s = type.rawValue.lowercased()
                guard s.contains("png") || s.contains("jpeg") || s.contains("jpg")
                        || s.contains("tiff") || s.contains("gif") || s.contains("webp")
                        || s.contains("heic") || s.contains("bmp")
                else { continue }
                if let data = item.data(forType: type), let img = NSImage(data: data) {
                    return (data, img)
                }
            }
        }
        // Last resort: let AppKit figure it out. NSImage(pasteboard:) handles
        // odd flavours (PDF screenshots, drag previews, etc.). We round-trip
        // through TIFF so we have a concrete Data to write to disk.
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation {
            return (tiff, img)
        }
        return nil
    }

    // MARK: - NSTextViewDelegate ---------------------------------------------

    func textDidChange(_ notification: Notification) {
        if !textView.string.isEmpty && !hasUserInteraction {
            hasUserInteraction = true
            hintLabel.isHidden = true
        } else if textView.string.isEmpty && pastedImageData == nil && pastedFileURL == nil {
            hasUserInteraction = false
            hintLabel.isHidden = false
        }
        onContentHeightChange?(preferredHeight())
    }
}

// MARK: - CaptureTextView -----------------------------------------------------

final class CaptureTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPasteRequest: (() -> Bool)?  // return true if handled

    override var acceptsFirstResponder: Bool { true }

    override func paste(_ sender: Any?) {
        if let handler = onPasteRequest, handler() { return }
        super.paste(sender)
    }

    /// Borderless windows don't get the system main menu's key equivalents,
    /// so the standard editing commands (Cmd+A, Cmd+C, Cmd+X, Cmd+Z, …) never
    /// reach the text view. Dispatch them explicitly here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        if mods == .command {
            switch chars {
            case "a": selectAll(nil);     return true
            case "c": copy(nil);          return true
            case "x": cut(nil);           return true
            case "v": paste(nil);         return true
            case "z":
                undoManager?.undo()
                return true
            default: break
            }
        }
        if mods == [.command, .shift] {
            if chars.lowercased() == "z" {
                undoManager?.redo()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / numeric Return
            // Submit on bare Return; pass through to default newline insertion
            // for Shift+Return (or any other modifier so we don't swallow
            // command-Return chords if the user binds something to them).
            let interesting = event.modifierFlags.intersection(
                [.command, .option, .control, .shift]
            )
            if interesting.isEmpty {
                onSubmit?()
                return
            }
            if interesting == .shift {
                insertNewline(nil)
                return
            }
        }
        super.keyDown(with: event)
    }
}
