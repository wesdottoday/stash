import AppKit

/// A toast-style, foreground-but-non-focus-stealing panel that shows the
/// recording state while the user keeps working: a red dot, an elapsed timer,
/// and a rolling one-line live transcript, plus a Stop button.
///
/// It reuses `CaptureWindow`'s `.nonactivatingPanel` recipe so it never pulls
/// the app's Dock/Cmd-Tab activation. It *does* become key while shown so it
/// can receive Escape (discard) — clicking back into another app hands key
/// status back, after which the global voice chord (toggle) and the Stop button
/// (mouse) still work.
final class VoiceToastPanel: NSPanel {
    var onStop: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let toastView = VoiceToastView()
    private var elapsedTimer: Timer?
    private var sessionStart: Date?
    private var autoHideWork: DispatchWorkItem?

    init() {
        let initial = NSRect(x: 0, y: 0, width: 360, height: 56)
        super.init(contentRect: initial,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isMovableByWindowBackground = true
        isMovable = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        contentView = toastView
        toastView.onStop = { [weak self] in self?.onStop?() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - State presentation

    /// Show the toast in its "starting…" state (immediate feedback after the
    /// chord, before the engine is live).
    func showPreparing() {
        cancelAutoHide()
        stopTimer()
        toastView.showPreparing()
        positionTopRight()
        makeKeyAndOrderFront(nil)
    }

    /// Recording is live — begin the elapsed timer from `start`.
    func startRecording(from start: Date) {
        cancelAutoHide()
        sessionStart = start
        toastView.showRecording()
        positionTopRight()
        if !isVisible { makeKeyAndOrderFront(nil) }
        startTimer()
    }

    /// Recording stopped, now finalizing/saving — show a non-interactive
    /// "Saving…" state (no Stop/discard affordance, since it's a point of no
    /// return: the audio is already captured).
    func showFinalizing() {
        stopTimer()
        toastView.showFinalizing()
        if !isVisible { positionTopRight(); makeKeyAndOrderFront(nil) }
    }

    func setLiveLine(_ text: String) { toastView.setLiveLine(text) }
    func setLevel(_ level: Float) { toastView.setLevel(level) }

    func hide() {
        cancelAutoHide()
        stopTimer()
        sessionStart = nil
        orderOut(nil)
    }

    /// Surface a transient error on the toast, then auto-hide it. Used because
    /// an `.accessory` app has no window to anchor a system alert.
    func showError(_ message: String) {
        stopTimer()
        sessionStart = nil
        toastView.showError(message)
        sizeToFit()
        positionTopRight()
        makeKeyAndOrderFront(nil)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        updateElapsed()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func updateElapsed() {
        guard let start = sessionStart else { return }
        toastView.setElapsed(Date().timeIntervalSince(start))
    }

    private func cancelAutoHide() {
        autoHideWork?.cancel()
        autoHideWork = nil
    }

    // MARK: - Layout / position

    private func sizeToFit() {
        var f = frame
        f.size = NSSize(width: 360, height: toastView.preferredHeight())
        setFrame(f, display: false)
    }

    private func positionTopRight() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { center(); return }
        let margin: CGFloat = 16
        let size = frame.size
        setFrameOrigin(NSPoint(x: visible.maxX - size.width - margin,
                               y: visible.maxY - size.height - margin))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDiscard?(); return }   // Escape → discard
        super.keyDown(with: event)
    }

    /// Escape is also delivered as `cancelOperation` to the responder chain.
    override func cancelOperation(_ sender: Any?) {
        onDiscard?()
    }
}

// MARK: - Toast content view -------------------------------------------------

private final class VoiceToastView: NSView {
    var onStop: (() -> Void)?

    private let visualEffect = NSVisualEffectView()
    private let dot = RecordingDotView()
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let liveLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "esc to discard")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }
    required init?(coder: NSCoder) { nil }

    private func setup() {
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

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 12).isActive = true

        timerLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timerLabel.textColor = .labelColor
        timerLabel.alignment = .left
        timerLabel.setContentHuggingPriority(.required, for: .horizontal)
        timerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        liveLabel.font = .systemFont(ofSize: 12)
        liveLabel.textColor = .secondaryLabelColor
        liveLabel.lineBreakMode = .byTruncatingTail
        liveLabel.usesSingleLineMode = true
        liveLabel.cell?.truncatesLastVisibleLine = true
        liveLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        liveLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .regular
        stopButton.keyEquivalent = "\r"          // Return also stops (saves)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .right

        let topRow = NSStackView(views: [dot, timerLabel, liveLabel, stopButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [topRow, hintLabel])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            topRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
    }

    func preferredHeight() -> CGFloat { 56 }

    @objc private func stopClicked() { onStop?() }

    // MARK: - State

    func showPreparing() {
        dot.isAnimating = false
        dot.isHidden = false
        timerLabel.stringValue = "00:00"
        liveLabel.stringValue = "Starting…"
        liveLabel.textColor = .secondaryLabelColor
        stopButton.isHidden = false
        stopButton.isEnabled = true
        hintLabel.isHidden = false
    }

    func showRecording() {
        dot.isHidden = false
        dot.isAnimating = true
        liveLabel.textColor = .secondaryLabelColor
        if liveLabel.stringValue == "Starting…" { liveLabel.stringValue = "Listening…" }
        stopButton.isHidden = false
        stopButton.isEnabled = true
        hintLabel.isHidden = false
    }

    func showFinalizing() {
        dot.isAnimating = false
        dot.isHidden = false
        liveLabel.stringValue = "Saving…"
        liveLabel.textColor = .secondaryLabelColor
        stopButton.isHidden = true     // point of no return — no Stop/discard
        hintLabel.isHidden = true
    }

    func showError(_ message: String) {
        dot.isAnimating = false
        dot.isHidden = true
        timerLabel.stringValue = "⚠"
        liveLabel.stringValue = message
        liveLabel.textColor = .systemRed
        stopButton.isHidden = true
        hintLabel.isHidden = true
    }

    func setElapsed(_ seconds: TimeInterval) {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        timerLabel.stringValue = String(format: "%02d:%02d", m, s)
    }

    func setLiveLine(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        liveLabel.stringValue = trimmed.isEmpty ? "Listening…" : trimmed
        liveLabel.textColor = .secondaryLabelColor
    }

    func setLevel(_ level: Float) {
        dot.level = CGFloat(max(0, min(1, level)))
    }
}

// MARK: - Recording dot ------------------------------------------------------

/// A steady red dot — the unmistakable recording indicator. It breathes subtly
/// with the input level so silence vs. speech is visible at a glance.
private final class RecordingDotView: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }
    var isAnimating: Bool = false {
        didSet { isHidden ? () : (needsDisplay = true) }
    }

    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isAnimating ? (2 - level * 1.5) : 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}
