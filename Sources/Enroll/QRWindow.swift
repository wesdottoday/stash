import AppKit
import CoreImage

/// Renders a `stash://enroll?…&k=…` URL as a QR code (via Core Image's
/// `CIQRCodeGenerator`, a system framework — no third-party dep) and shows it
/// in a small window for another device to scan with its Camera.
///
/// The URL carries the E2E key in its `k` fragment, so the QR is the
/// device-to-device key transfer; the raw URL text is intentionally **not**
/// displayed (it would expose the key to shoulder-surfing — the QR is meant to
/// be scanned, not read).
final class QRWindowController: NSWindowController {

    private let imageView = NSImageView()
    private let captionLabel = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Link a device"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildLayout()
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)

        captionLabel.stringValue = "Open the Camera on your iPhone and point it at this code to link it. The code expires in about 15 minutes."
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.alignment = .center
        captionLabel.usesSingleLineMode = false
        captionLabel.maximumNumberOfLines = 0
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [imageView, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            imageView.widthAnchor.constraint(equalToConstant: 260),
            imageView.heightAnchor.constraint(equalToConstant: 260),
        ])
    }

    /// Show the window displaying a QR for `url`. Returns false if the QR
    /// couldn't be generated.
    @discardableResult
    func present(url: URL) -> Bool {
        guard let image = QRWindowController.qrImage(from: url.absoluteString) else { return false }
        imageView.image = image
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Generate a crisp QR `NSImage` from a string using `CIQRCodeGenerator`.
    static func qrImage(from string: String, scale: CGFloat = 10) -> NSImage? {
        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // Medium error correction — a good balance of density vs. robustness.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
