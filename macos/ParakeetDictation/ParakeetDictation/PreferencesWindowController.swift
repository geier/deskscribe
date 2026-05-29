import AppKit

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let hotKeyButton = NSButton(title: "", target: nil, action: nil)
    private let triggerModePopup = NSPopUpButton()
    private let modelRepoField = NSTextField(string: "")
    private let modelFileField = NSTextField(string: "")
    private let modelPresetPopup = NSPopUpButton()
    private let vocabularyTextView = NSTextView()
    private let vocabularyScrollView = NSScrollView()
    private var capturedHotKey = AppSettings.hotKey
    private var selectedTriggerMode = AppSettings.triggerMode
    private var captureMonitor: Any?
    private let onSave: (HotKeySettings, TriggerMode, ModelSettings, VocabularySettings) -> Void
    private let onCaptureStarted: () -> Void
    private let onCaptureEnded: () -> Void

    init(
        onSave: @escaping (HotKeySettings, TriggerMode, ModelSettings, VocabularySettings) -> Void,
        onCaptureStarted: @escaping () -> Void,
        onCaptureEnded: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCaptureStarted = onCaptureStarted
        self.onCaptureEnded = onCaptureEnded

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ParakeetDictation Preferences"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        loadSettings()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        modelPresetPopup.addItems(withTitles: ["primeline/parakeet-primeline", "Custom"])
        modelPresetPopup.target = self
        modelPresetPopup.action = #selector(modelPresetChanged)

        triggerModePopup.addItems(withTitles: TriggerMode.allCases.map(\.displayName))
        triggerModePopup.target = self
        triggerModePopup.action = #selector(triggerModeChanged)

        hotKeyButton.target = self
        hotKeyButton.action = #selector(captureHotKey)
        hotKeyButton.bezelStyle = .rounded

        vocabularyTextView.font = .systemFont(ofSize: 13)
        vocabularyTextView.isRichText = false
        vocabularyTextView.allowsUndo = true
        vocabularyScrollView.documentView = vocabularyTextView
        vocabularyScrollView.hasVerticalScroller = true
        vocabularyScrollView.borderType = .bezelBorder

        stack.addArrangedSubview(row(label: "Hotkey", control: hotKeyButton))
        stack.addArrangedSubview(row(label: "Trigger", control: triggerModePopup))
        stack.addArrangedSubview(row(label: "Model", control: modelPresetPopup))
        stack.addArrangedSubview(row(label: "Repo", control: modelRepoField))
        stack.addArrangedSubview(row(label: "File", control: modelFileField))
        stack.addArrangedSubview(row(label: "Vocabulary", control: vocabularyScrollView))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let resetButton = NSButton(title: "Defaults", target: self, action: #selector(resetDefaults))
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"

        buttons.addArrangedSubview(resetButton)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttons)

        buttons.widthAnchor.constraint(equalToConstant: 480).isActive = true
        modelRepoField.widthAnchor.constraint(equalToConstant: 350).isActive = true
        modelFileField.widthAnchor.constraint(equalToConstant: 350).isActive = true
        hotKeyButton.widthAnchor.constraint(equalToConstant: 180).isActive = true
        triggerModePopup.widthAnchor.constraint(equalToConstant: 350).isActive = true
        modelPresetPopup.widthAnchor.constraint(equalToConstant: 350).isActive = true
        vocabularyScrollView.widthAnchor.constraint(equalToConstant: 350).isActive = true
        vocabularyScrollView.heightAnchor.constraint(equalToConstant: 92).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24)
        ])
    }

    private func row(label: String, control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    private func loadSettings() {
        capturedHotKey = AppSettings.hotKey
        selectedTriggerMode = AppSettings.triggerMode
        let model = AppSettings.model
        let vocabulary = AppSettings.vocabulary
        hotKeyButton.title = AppSettings.displayName(for: capturedHotKey)
        triggerModePopup.selectItem(withTitle: selectedTriggerMode.displayName)
        modelRepoField.stringValue = model.repo
        modelFileField.stringValue = model.file
        vocabularyTextView.string = vocabulary.words.joined(separator: "\n")
        modelPresetPopup.selectItem(withTitle: model == AppSettings.defaultModel ? "primeline/parakeet-primeline" : "Custom")
    }

    @objc private func captureHotKey() {
        hotKeyButton.title = "Press shortcut..."
        if let captureMonitor {
            NSEvent.removeMonitor(captureMonitor)
        }
        onCaptureStarted()

        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = AppSettings.modifiers(from: event)
            guard !modifiers.isEmpty else {
                self.hotKeyButton.title = "Use a modifier key"
                return nil
            }

            self.capturedHotKey = HotKeySettings(keyCode: CGKeyCode(event.keyCode), modifiers: modifiers)
            self.hotKeyButton.title = AppSettings.displayName(for: self.capturedHotKey)
            self.endCapture()
            return nil
        }
    }

    @objc private func modelPresetChanged() {
        if modelPresetPopup.titleOfSelectedItem == "primeline/parakeet-primeline" {
            modelRepoField.stringValue = AppSettings.defaultModel.repo
            modelFileField.stringValue = AppSettings.defaultModel.file
        }
    }

    @objc private func triggerModeChanged() {
        let title = triggerModePopup.titleOfSelectedItem ?? ""
        selectedTriggerMode = TriggerMode.allCases.first { $0.displayName == title } ?? AppSettings.defaultTriggerMode
    }

    @objc private func resetDefaults() {
        capturedHotKey = AppSettings.defaultHotKey
        selectedTriggerMode = AppSettings.defaultTriggerMode
        hotKeyButton.title = AppSettings.displayName(for: capturedHotKey)
        triggerModePopup.selectItem(withTitle: selectedTriggerMode.displayName)
        modelRepoField.stringValue = AppSettings.defaultModel.repo
        modelFileField.stringValue = AppSettings.defaultModel.file
        vocabularyTextView.string = AppSettings.defaultVocabulary.words.joined(separator: "\n")
        modelPresetPopup.selectItem(withTitle: "primeline/parakeet-primeline")
    }

    @objc private func cancel() {
        endCapture()
        window?.orderOut(nil)
    }

    @objc private func save() {
        let model = ModelSettings(
            repo: modelRepoField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            file: modelFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let vocabulary = VocabularySettings(
            words: AppSettings.normalizedVocabulary(vocabularyTextView.string.components(separatedBy: .newlines))
        )
        guard !model.repo.isEmpty, !model.file.isEmpty else { return }

        AppSettings.hotKey = capturedHotKey
        AppSettings.triggerMode = selectedTriggerMode
        AppSettings.model = model
        AppSettings.vocabulary = vocabulary
        endCapture()
        onSave(capturedHotKey, selectedTriggerMode, model, vocabulary)
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        endCapture()
    }

    private func endCapture() {
        guard let captureMonitor else { return }
        NSEvent.removeMonitor(captureMonitor)
        self.captureMonitor = nil
        onCaptureEnded()
    }
}
