import AppKit

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let hotKeyButton = NSButton(title: "", target: nil, action: nil)
    private let triggerModePopup = NSPopUpButton()
    private let modelRepoField = NSTextField(string: "")
    private let modelFileField = NSTextField(string: "")
    private let modelPresetPopup = NSPopUpButton()
    private let vocabularyTextView = NSTextView()
    private let vocabularyScrollView = NSScrollView()
    private let vocabularyParseStatusLabel = NSTextField(labelWithString: "")
    private let restorePasteboardCheckbox = NSButton(checkboxWithTitle: "Restore clipboard after pasting", target: nil, action: nil)
    private var modelRepoRow: NSStackView?
    private var modelFileRow: NSStackView?
    private var capturedHotKey = AppSettings.hotKey
    private var selectedTriggerMode = AppSettings.triggerMode
    private var captureMonitor: Any?
    private let onSave: (HotKeySettings, TriggerMode, ModelSettings, VocabularySettings, Bool) -> Void
    private let onCheckPermissions: () -> Void
    private let onCaptureStarted: () -> Void
    private let onCaptureEnded: () -> Void

    init(
        onSave: @escaping (HotKeySettings, TriggerMode, ModelSettings, VocabularySettings, Bool) -> Void,
        onCheckPermissions: @escaping () -> Void,
        onCaptureStarted: @escaping () -> Void,
        onCaptureEnded: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCheckPermissions = onCheckPermissions
        self.onCaptureStarted = onCaptureStarted
        self.onCaptureEnded = onCaptureEnded

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppVariant.displayName) Preferences"
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

        modelPresetPopup.addItems(withTitles: Self.modelPresetTitles)
        modelPresetPopup.target = self
        modelPresetPopup.action = #selector(modelPresetChanged)
#if DESKSCRIBE_NATIVE_ONNX
        modelPresetPopup.isEnabled = false
#endif

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
#if !DESKSCRIBE_NATIVE_ONNX
        let repoRow = row(label: "Repo", control: modelRepoField)
        let fileRow = row(label: "File", control: modelFileField)
        modelRepoRow = repoRow
        modelFileRow = fileRow
        stack.addArrangedSubview(repoRow)
        stack.addArrangedSubview(fileRow)
#endif
        stack.addArrangedSubview(row(label: "Vocabulary", control: vocabularyControl()))
        stack.addArrangedSubview(row(label: "Clipboard", control: restorePasteboardCheckbox))

        let permissionsButton = NSButton(title: "Check Permissions", target: self, action: #selector(checkPermissions))
        permissionsButton.bezelStyle = .rounded
        stack.addArrangedSubview(row(label: "Permissions", control: permissionsButton))

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
        restorePasteboardCheckbox.widthAnchor.constraint(equalToConstant: 350).isActive = true

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
        restorePasteboardCheckbox.state = AppSettings.restorePasteboardAfterPaste ? .on : .off
        modelPresetPopup.selectItem(withTitle: model == AppSettings.defaultModel ? Self.defaultModelTitle : "Custom")
        updateModelFieldsVisibility()
    }

    private static var defaultModelTitle: String {
#if DESKSCRIBE_NATIVE_ONNX
        "DeskScribe ONNX default"
#else
        "primeline/parakeet-primeline"
#endif
    }

    private static var modelPresetTitles: [String] {
#if DESKSCRIBE_NATIVE_ONNX
        [defaultModelTitle]
#else
        [defaultModelTitle, "Custom"]
#endif
    }

    private func vocabularyControl() -> NSStackView {
        let helpText = NSTextField(wrappingLabelWithString: "Optional pronunciation/spelling hints. Add one entry per line, for example: DeskScribe or desk scribe => DeskScribe")
        helpText.textColor = .secondaryLabelColor
        helpText.font = .systemFont(ofSize: 11)

        let helpButton = NSButton(title: "Vocabulary Help", target: self, action: #selector(showVocabularyHelp))
        helpButton.bezelStyle = .rounded

        let testButton = NSButton(title: "Test Parsing", target: self, action: #selector(testVocabularyParsing))
        testButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [testButton, helpButton, vocabularyParseStatusLabel])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        vocabularyParseStatusLabel.textColor = .secondaryLabelColor
        vocabularyParseStatusLabel.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [vocabularyScrollView, helpText, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        helpText.widthAnchor.constraint(equalToConstant: 350).isActive = true
        return stack
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
        if modelPresetPopup.titleOfSelectedItem == Self.defaultModelTitle {
            modelRepoField.stringValue = AppSettings.defaultModel.repo
            modelFileField.stringValue = AppSettings.defaultModel.file
        }
        updateModelFieldsVisibility()
    }

    private func updateModelFieldsVisibility() {
        let isCustom = modelPresetPopup.titleOfSelectedItem == "Custom"
        modelRepoRow?.isHidden = !isCustom
        modelFileRow?.isHidden = !isCustom
        modelRepoField.isEditable = isCustom
        modelFileField.isEditable = isCustom
    }

    @objc private func triggerModeChanged() {
        let title = triggerModePopup.titleOfSelectedItem ?? ""
        selectedTriggerMode = TriggerMode.allCases.first { $0.displayName == title } ?? AppSettings.defaultTriggerMode
    }

    @objc private func checkPermissions() {
        onCheckPermissions()
    }

    @objc private func showVocabularyHelp() {
        let alert = NSAlert()
        alert.messageText = "Vocabulary Hints"
        alert.informativeText = "Use this for product names, people, acronyms, or words the recognizer often misspells.\n\nOne entry per line:\nPreferred spelling\nmisheard phrase => preferred spelling\nother variant -> preferred spelling\n\nExamples:\nDeskScribe\ndesk scribe => DeskScribe\npost grass -> Postgres"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func testVocabularyParsing() {
        let result = vocabularyParseResult()
        let issues = result.issues
        highlightVocabularyIssues(issues)
        if issues.isEmpty {
            vocabularyParseStatusLabel.stringValue = "\(result.accepted.count) accepted"
            vocabularyParseStatusLabel.textColor = .systemGreen
        } else {
            vocabularyParseStatusLabel.stringValue = "\(issues.count) broken line\(issues.count == 1 ? "" : "s")"
            vocabularyParseStatusLabel.textColor = .systemRed
        }

        let alert = NSAlert()
        alert.messageText = issues.isEmpty ? "Vocabulary Parsing Passed" : "Vocabulary Parsing Found Issues"
        let acceptedText = result.accepted.isEmpty ? "No vocabulary entries." : result.accepted.joined(separator: "\n")
        alert.informativeText = "Accepted entries:\n\(acceptedText)"
        alert.alertStyle = issues.isEmpty ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func vocabularyParseResult() -> (accepted: [String], issues: [NSRange]) {
        let text = vocabularyTextView.string as NSString
        var issues: [NSRange] = []
        var accepted: [String] = []
        var offset = 0

        for rawLine in vocabularyTextView.string.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lineRange = text.lineRange(for: NSRange(location: offset, length: min(rawLine.count, text.length - offset)))
            offset += rawLine.count + 1

            guard !line.isEmpty else { continue }
            let separator: String?
            if line.contains("=>") {
                separator = "=>"
            } else if line.contains("->") {
                separator = "->"
            } else {
                separator = nil
            }

            guard let separator else {
                accepted.append(line)
                continue
            }
            let parts = line.components(separatedBy: separator)
            if parts.count != 2 || parts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(lineRange)
            } else {
                accepted.append("\(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) -> \(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        return (accepted, issues)
    }

    private func highlightVocabularyIssues(_ issues: [NSRange]) {
        let fullRange = NSRange(location: 0, length: (vocabularyTextView.string as NSString).length)
        vocabularyTextView.textStorage?.removeAttribute(.foregroundColor, range: fullRange)
        vocabularyTextView.textStorage?.removeAttribute(.backgroundColor, range: fullRange)
        vocabularyTextView.textStorage?.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)

        for range in issues {
            vocabularyTextView.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
            vocabularyTextView.textStorage?.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.12), range: range)
        }
    }

    @objc private func resetDefaults() {
        capturedHotKey = AppSettings.defaultHotKey
        selectedTriggerMode = AppSettings.defaultTriggerMode
        hotKeyButton.title = AppSettings.displayName(for: capturedHotKey)
        triggerModePopup.selectItem(withTitle: selectedTriggerMode.displayName)
        modelRepoField.stringValue = AppSettings.defaultModel.repo
        modelFileField.stringValue = AppSettings.defaultModel.file
        vocabularyTextView.string = AppSettings.defaultVocabulary.words.joined(separator: "\n")
        restorePasteboardCheckbox.state = AppSettings.defaultRestorePasteboardAfterPaste ? .on : .off
        modelPresetPopup.selectItem(withTitle: Self.defaultModelTitle)
        updateModelFieldsVisibility()
    }

    @objc private func cancel() {
        endCapture()
        window?.orderOut(nil)
    }

    @objc private func save() {
        let model: ModelSettings
        if modelPresetPopup.titleOfSelectedItem == "Custom" {
            model = ModelSettings(
                repo: modelRepoField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                file: modelFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else {
            model = AppSettings.defaultModel
        }
        let vocabulary = VocabularySettings(
            words: AppSettings.normalizedVocabulary(vocabularyTextView.string.components(separatedBy: .newlines))
        )
        guard !model.repo.isEmpty, !model.file.isEmpty else { return }

        AppSettings.hotKey = capturedHotKey
        AppSettings.triggerMode = selectedTriggerMode
        AppSettings.model = model
        AppSettings.vocabulary = vocabulary
        AppSettings.restorePasteboardAfterPaste = restorePasteboardCheckbox.state == .on
        endCapture()
        onSave(capturedHotKey, selectedTriggerMode, model, vocabulary, AppSettings.restorePasteboardAfterPaste)
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
