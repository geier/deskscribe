import AppKit

final class TranscriptOverlay {
    private let panel: NSPanel
    private let scrollView: NSScrollView
    private let textView: NSTextView
    private var hideWorkItem: DispatchWorkItem?
    private let horizontalPadding: CGFloat = 28
    private let verticalPadding: CGFloat = 22
    private let font = NSFont.systemFont(ofSize: 24, weight: .medium)
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

        textView = NSTextView(frame: .zero)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.textColor = .white
        textView.font = font
        textView.alignment = .center
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: verticalPadding),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -verticalPadding)
        ])

        panel.contentView = contentView
    }

    func show(_ text: String) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        resizePanel(for: text)
        textView.string = text
        scrollToBottom()
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
        let textWidth = width - horizontalPadding * 2

        let measured = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let maxTextHeight = ceil(lineHeight * CGFloat(maxLines))
        let fullTextHeight = ceil(measured)
        let visibleTextHeight = min(maxTextHeight, fullTextHeight)
        let height = max(92, visibleTextHeight + verticalPadding * 2)

        panel.setContentSize(NSSize(width: width, height: height))
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(fullTextHeight, height - verticalPadding * 2))
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
    }

    private func scrollToBottom() {
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        textView.scrollRangeToVisible(end)
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
