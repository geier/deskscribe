import AppKit

final class TranscriptOverlay {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 130)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let contentView = NSView(frame: frame)
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 18
        contentView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor

        label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.textColor = .white

        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        panel.contentView = contentView
    }

    func show(_ text: String) {
        label.stringValue = text
        positionPanel()
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    private func positionPanel() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 120
        )
        panel.setFrameOrigin(origin)
    }
}
