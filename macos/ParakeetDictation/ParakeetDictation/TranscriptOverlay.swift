import AppKit

final class TranscriptOverlay {
    private let panel: NSPanel
    private let label: NSTextField
    private var hideWorkItem: DispatchWorkItem?
    private let horizontalPadding: CGFloat = 28
    private let verticalPadding: CGFloat = 22
    private let maxLines = 8

    private(set) var isVisible = false

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
        label.maximumNumberOfLines = maxLines
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.textColor = .white

        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        panel.contentView = contentView
    }

    func show(_ text: String) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        label.stringValue = text
        resizePanel(for: text)
        positionPanel()
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.orderOut(nil)
        isVisible = false
    }

    private func resizePanel(for text: String) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(560, screenFrame.width - 160), 760)
        let labelWidth = width - horizontalPadding * 2
        label.preferredMaxLayoutWidth = labelWidth

        let font = label.font ?? .systemFont(ofSize: 24, weight: .medium)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: labelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let maxTextHeight = ceil(lineHeight * CGFloat(maxLines))
        let textHeight = min(maxTextHeight, ceil(measured))
        let height = max(92, textHeight + verticalPadding * 2)

        panel.setContentSize(NSSize(width: width, height: height))
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
