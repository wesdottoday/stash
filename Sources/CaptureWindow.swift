import AppKit

final class CaptureWindow: NSPanel {
    var onSubmit: ((CapturePayload) -> Void)?
    var onDismiss: (() -> Void)?
    var onPositionChange: ((NSPoint) -> Void)?

    let captureView: CaptureView

    init() {
        captureView = CaptureView()
        let initial = NSRect(x: 0, y: 0, width: 640, height: 64)
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

        contentView = captureView

        captureView.onSubmitPayload = { [weak self] payload in
            self?.onSubmit?(payload)
        }
        captureView.onCancel = { [weak self] in
            self?.onDismiss?()
        }
        captureView.onContentHeightChange = { [weak self] _ in
            self?.relayoutForContent()
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didMove(_:)),
                                               name: NSWindow.didMoveNotification,
                                               object: self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func showCapture(at savedPosition: NSPoint?) {
        captureView.prepareForShow()
        sizeToFitContent()
        positionWindow(savedPosition)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(captureView.firstResponderTarget)
    }

    func dismissCapture() {
        orderOut(nil)
        captureView.resetState()
    }

    func showConfirmation(durationMs: Int, completion: @escaping () -> Void) {
        captureView.showConfirmationIndicator()
        let delay = max(50, min(500, durationMs))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            self?.captureView.hideConfirmationIndicator()
            completion()
        }
    }

    @objc private func didMove(_ note: Notification) {
        onPositionChange?(frame.origin)
    }

    private func positionWindow(_ saved: NSPoint?) {
        if let p = saved, NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: p, size: frame.size)) }) {
            setFrameOrigin(p)
        } else {
            center()
        }
    }

    private func sizeToFitContent() {
        let height = captureView.preferredHeight()
        var f = frame
        f.size = NSSize(width: 640, height: height)
        setFrame(f, display: false)
    }

    private func relayoutForContent() {
        let target = captureView.preferredHeight()
        var f = frame
        let delta = target - f.size.height
        guard abs(delta) > 0.5 else { return }
        // Anchor to top so the window grows downward visually.
        f.origin.y -= delta
        f.size.height = target
        setFrame(f, display: true)
    }
}
