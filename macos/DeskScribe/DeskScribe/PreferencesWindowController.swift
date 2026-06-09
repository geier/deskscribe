import AppKit
import UniformTypeIdentifiers

private enum StartupLaunchAgent {
    private static var label: String {
        "\(Bundle.main.bundleIdentifier ?? "local.DeskScribe").startup"
    }

    private static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private static var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    private static var currentBundlePath: String {
        Bundle.main.bundleURL.path
    }

    static var configuredBundlePath: String? {
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let args = plist["ProgramArguments"] as? [String],
            args.count >= 3,
            args[0] == "/usr/bin/open",
            args[1] == "-a"
        else {
            return nil
        }
        return args[2]
    }

    static var isEnabledForCurrentBundle: Bool {
        configuredBundlePath == currentBundlePath
    }

    static func enable() throws {
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", currentBundlePath],
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    static func disable() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum TableID {
        static let vocabulary = NSUserInterfaceItemIdentifier("VocabularyTable")
        static let history = NSUserInterfaceItemIdentifier("HistoryTable")
    }

    private let hotKeyButton = NSButton(title: "", target: nil, action: nil)
    private let triggerModePopup = NSPopUpButton()
    private let modelRepoField = NSTextField(string: "")
    private let modelFileField = NSTextField(string: "")
    private let modelPresetPopup = NSPopUpButton()
    private let modelInfoButton = NSButton(title: "i", target: nil, action: nil)
    private let modelLanguagesLabel = NSTextField(wrappingLabelWithString: "")
    private let modelBestForLabel = NSTextField(wrappingLabelWithString: "")
    private let modelNotesLabel = NSTextField(wrappingLabelWithString: "")
    private let restorePasteboardCheckbox = NSButton(checkboxWithTitle: "Restore clipboard after pasting", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Open automatically at login", target: nil, action: nil)
    private let vocabularyTableView = NSTableView()
    private let vocabularyPhraseField = NSTextField(string: "")
    private let vocabularyReplacementField = NSTextField(string: "")
    private let vocabularyStatusLabel = NSTextField(labelWithString: "")
    private let historyTableView = NSTableView()
    private let statsLabel = NSTextField(wrappingLabelWithString: "")
    private var modelRepoRow: NSStackView?
    private var modelFileRow: NSStackView?
    private var vocabularyEntries: [VocabularyEntry] = []
    private var historyEntries: [TranscriptHistoryEntry] = []
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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
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

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(tabView)

        tabView.addTabViewItem(tab(title: "General", view: generalPane()))
        tabView.addTabViewItem(tab(title: "Model", view: modelPane()))
        tabView.addTabViewItem(tab(title: "Vocabulary", view: vocabularyPane()))
        tabView.addTabViewItem(tab(title: "History & Stats", view: historyPane()))

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
        root.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            tabView.widthAnchor.constraint(equalToConstant: 644),
            tabView.heightAnchor.constraint(equalToConstant: 462),
            buttons.widthAnchor.constraint(equalToConstant: 644)
        ])
    }

    private func tab(title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func paneStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 18)
        ])
        return stack
    }

    private func generalPane() -> NSView {
        let stack = paneStack()
        guard let wrapper = stack.superview else { return stack }

        triggerModePopup.addItems(withTitles: TriggerMode.allCases.map(\.displayName))
        triggerModePopup.target = self
        triggerModePopup.action = #selector(triggerModeChanged)

        hotKeyButton.target = self
        hotKeyButton.action = #selector(captureHotKey)
        hotKeyButton.bezelStyle = .rounded

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)

        let permissionsButton = NSButton(title: "Check Permissions", target: self, action: #selector(checkPermissions))
        permissionsButton.bezelStyle = .rounded

        stack.addArrangedSubview(row(label: "Hotkey", control: hotKeyButton))
        stack.addArrangedSubview(row(label: "Trigger", control: triggerModePopup))
        stack.addArrangedSubview(row(label: "Clipboard", control: restorePasteboardCheckbox))
        stack.addArrangedSubview(row(label: "Login", control: launchAtLoginCheckbox))
        stack.addArrangedSubview(row(label: "Permissions", control: permissionsButton))

        hotKeyButton.widthAnchor.constraint(equalToConstant: 180).isActive = true
        triggerModePopup.widthAnchor.constraint(equalToConstant: 360).isActive = true
        restorePasteboardCheckbox.widthAnchor.constraint(equalToConstant: 360).isActive = true
        launchAtLoginCheckbox.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return wrapper
    }

    private func modelPane() -> NSView {
        let stack = paneStack()
        guard let wrapper = stack.superview else { return stack }

        modelPresetPopup.addItems(withTitles: Self.modelPresetTitles)
        modelPresetPopup.target = self
        modelPresetPopup.action = #selector(modelPresetChanged)
        modelInfoButton.target = self
        modelInfoButton.action = #selector(showModelInfo)
        modelInfoButton.bezelStyle = .helpButton
        modelInfoButton.title = ""
        configureModelDetailLabel(modelLanguagesLabel)
        configureModelDetailLabel(modelBestForLabel)
        configureModelDetailLabel(modelNotesLabel)

        stack.addArrangedSubview(row(label: "Model", control: horizontalControls([modelPresetPopup, modelInfoButton])))
        stack.addArrangedSubview(row(label: "Languages", control: modelLanguagesLabel))
        stack.addArrangedSubview(row(label: "Best for", control: modelBestForLabel))
        stack.addArrangedSubview(row(label: "Notes", control: modelNotesLabel))
        modelPresetPopup.widthAnchor.constraint(equalToConstant: 420).isActive = true
        modelLanguagesLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        modelBestForLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        modelNotesLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return wrapper
    }

    private func configureModelDetailLabel(_ label: NSTextField) {
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
    }

    private func vocabularyPane() -> NSView {
        let stack = paneStack()
        guard let wrapper = stack.superview else { return stack }

        configureVocabularyTable()
        let scroll = NSScrollView()
        scroll.documentView = vocabularyTableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 590).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 230).isActive = true

        let help = NSTextField(wrappingLabelWithString: "Add preferred spellings, or define replacements for phrases DeskScribe should rewrite after transcription.")
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: 11)
        help.widthAnchor.constraint(equalToConstant: 590).isActive = true

        let addWord = NSButton(title: "Add Word", target: self, action: #selector(addVocabularyWord))
        let addReplacement = NSButton(title: "Add Replacement", target: self, action: #selector(addVocabularyReplacement))
        let addExamples = NSButton(title: "Add DeskScribe Examples", target: self, action: #selector(addVocabularyExamples))
        let delete = NSButton(title: "Delete Selected", target: self, action: #selector(deleteVocabularyEntry))
        let importButton = NSButton(title: "Import JSON", target: self, action: #selector(importVocabulary))
        let exportButton = NSButton(title: "Export JSON", target: self, action: #selector(exportVocabulary))

        vocabularyPhraseField.placeholderString = "Word or recognized phrase"
        vocabularyReplacementField.placeholderString = "Write as"
        vocabularyPhraseField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        vocabularyReplacementField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        vocabularyStatusLabel.textColor = .secondaryLabelColor
        vocabularyStatusLabel.font = .systemFont(ofSize: 11)

        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(help)
        stack.addArrangedSubview(horizontalControls([vocabularyPhraseField, vocabularyReplacementField]))
        stack.addArrangedSubview(horizontalControls([addWord, addReplacement, addExamples, delete]))
        stack.addArrangedSubview(horizontalControls([importButton, exportButton, vocabularyStatusLabel]))
        return wrapper
    }

    private func historyPane() -> NSView {
        let stack = paneStack()
        guard let wrapper = stack.superview else { return stack }
        configureHistoryTable()

        let scroll = NSScrollView()
        scroll.documentView = historyTableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 590).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 270).isActive = true

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshHistory))
        let copy = NSButton(title: "Copy Selected", target: self, action: #selector(copySelectedTranscript))
        let clear = NSButton(title: "Clear History", target: self, action: #selector(clearHistory))

        statsLabel.widthAnchor.constraint(equalToConstant: 590).isActive = true
        stack.addArrangedSubview(statsLabel)
        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(horizontalControls([refresh, copy, clear]))
        return wrapper
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

    private func horizontalControls(_ controls: [NSView]) -> NSStackView {
        let stack = NSStackView(views: controls)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func verticalControls(_ controls: [NSView]) -> NSStackView {
        let stack = NSStackView(views: controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func configureVocabularyTable() {
        guard vocabularyTableView.tableColumns.isEmpty else { return }
        vocabularyTableView.identifier = TableID.vocabulary
        vocabularyTableView.delegate = self
        vocabularyTableView.dataSource = self
        vocabularyTableView.usesAlternatingRowBackgroundColors = true
        addColumn(to: vocabularyTableView, id: "type", title: "Type", width: 110)
        addColumn(to: vocabularyTableView, id: "phrase", title: "Phrase", width: 230)
        addColumn(to: vocabularyTableView, id: "replacement", title: "Replacement", width: 230)
    }

    private func configureHistoryTable() {
        guard historyTableView.tableColumns.isEmpty else { return }
        historyTableView.identifier = TableID.history
        historyTableView.delegate = self
        historyTableView.dataSource = self
        historyTableView.usesAlternatingRowBackgroundColors = true
        addColumn(to: historyTableView, id: "date", title: "Date", width: 160)
        addColumn(to: historyTableView, id: "words", title: "Words", width: 60)
        addColumn(to: historyTableView, id: "text", title: "Transcript", width: 360)
    }

    private func addColumn(to table: NSTableView, id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        table.addTableColumn(column)
    }

    private func loadSettings() {
        capturedHotKey = AppSettings.hotKey
        selectedTriggerMode = AppSettings.triggerMode
        let model = AppSettings.model
        hotKeyButton.title = AppSettings.displayName(for: capturedHotKey)
        triggerModePopup.selectItem(withTitle: selectedTriggerMode.displayName)
        modelRepoField.stringValue = model.repo
        modelFileField.stringValue = model.file
        restorePasteboardCheckbox.state = AppSettings.restorePasteboardAfterPaste ? .on : .off
        vocabularyEntries = VocabularyCodec.entries(from: AppSettings.vocabulary.words)
        vocabularyTableView.reloadData()
        updateVocabularyStatus()
        loadLaunchAtLoginState()
        modelPresetPopup.selectItem(withTitle: Self.title(for: model))
        updateModelDetails()
        updateModelFieldsVisibility()
        refreshHistory()
    }

    private static var defaultModelTitle: String {
        NativeONNXModelPresets.defaultPreset.title
    }

    private static var modelPresetTitles: [String] {
        NativeONNXModelPresets.all.map(\.title)
    }

    private static func title(for model: ModelSettings) -> String {
        NativeONNXModelPresets.preset(for: model).title
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView.identifier == TableID.vocabulary ? vocabularyEntries.count : historyEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        guard let id = tableColumn?.identifier.rawValue else { return cell }
        if tableView.identifier == TableID.vocabulary {
            let entry = vocabularyEntries[row]
            switch id {
            case "type": cell.stringValue = entry.kind == .word ? "Word" : "Replacement"
            case "phrase": cell.stringValue = entry.phrase
            case "replacement": cell.stringValue = entry.replacement ?? ""
            default: break
            }
        } else {
            let entry = historyEntries[row]
            switch id {
            case "date": cell.stringValue = Self.dateFormatter.string(from: entry.createdAt)
            case "words": cell.stringValue = String(entry.wordCount)
            case "text": cell.stringValue = entry.text
            default: break
            }
        }
        return cell
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func loadLaunchAtLoginState() {
        if StartupLaunchAgent.isEnabledForCurrentBundle {
            launchAtLoginCheckbox.state = .on
        } else if StartupLaunchAgent.configuredBundlePath != nil {
            launchAtLoginCheckbox.state = .on
        } else {
            launchAtLoginCheckbox.state = .off
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let shouldEnable = launchAtLoginCheckbox.state == .on
        do {
            if shouldEnable { try StartupLaunchAgent.enable() } else { try StartupLaunchAgent.disable() }
            loadLaunchAtLoginState()
        } catch {
            loadLaunchAtLoginState()
            showAlert(title: "Launch at Login Failed", message: error.localizedDescription, style: .warning)
        }
    }

    @objc private func addVocabularyWord() {
        let phrase = vocabularyPhraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        vocabularyEntries = VocabularyCodec.deduplicated(vocabularyEntries + [VocabularyEntry(kind: .word, phrase: phrase, replacement: nil)])
        vocabularyPhraseField.stringValue = ""
        vocabularyTableView.reloadData()
        updateVocabularyStatus()
    }

    @objc private func addVocabularyReplacement() {
        let phrase = vocabularyPhraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = vocabularyReplacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !replacement.isEmpty else { return }
        vocabularyEntries = VocabularyCodec.deduplicated(vocabularyEntries + [VocabularyEntry(kind: .replacement, phrase: phrase, replacement: replacement)])
        vocabularyPhraseField.stringValue = ""
        vocabularyReplacementField.stringValue = ""
        vocabularyTableView.reloadData()
        updateVocabularyStatus()
    }

    @objc private func addVocabularyExamples() {
        let examples = [
            VocabularyEntry(kind: .word, phrase: "DeskScribe", replacement: nil),
            VocabularyEntry(kind: .word, phrase: "ONNX", replacement: nil),
            VocabularyEntry(kind: .word, phrase: "Hugging Face", replacement: nil),
            VocabularyEntry(kind: .word, phrase: "macOS", replacement: nil),
            VocabularyEntry(kind: .word, phrase: "NVIDIA", replacement: nil),
            VocabularyEntry(kind: .word, phrase: "Parakeet", replacement: nil),
            VocabularyEntry(kind: .replacement, phrase: "desk scribe", replacement: "DeskScribe"),
            VocabularyEntry(kind: .replacement, phrase: "on X", replacement: "ONNX"),
            VocabularyEntry(kind: .replacement, phrase: "on next", replacement: "ONNX"),
            VocabularyEntry(kind: .replacement, phrase: "hugging face", replacement: "Hugging Face"),
            VocabularyEntry(kind: .replacement, phrase: "Mac OS", replacement: "macOS"),
            VocabularyEntry(kind: .replacement, phrase: "nvidia", replacement: "NVIDIA")
        ]
        let beforeCount = vocabularyEntries.count
        vocabularyEntries = VocabularyCodec.deduplicated(vocabularyEntries + examples)
        vocabularyTableView.reloadData()
        updateVocabularyStatus("Added \(vocabularyEntries.count - beforeCount) examples")
    }

    @objc private func deleteVocabularyEntry() {
        let selected = vocabularyTableView.selectedRowIndexes
        guard !selected.isEmpty else { return }
        for index in selected.reversed() {
            vocabularyEntries.remove(at: index)
        }
        vocabularyTableView.reloadData()
        updateVocabularyStatus()
    }

    @objc private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try VocabularyCodec.importEntries(from: Data(contentsOf: url))
            vocabularyEntries = VocabularyCodec.deduplicated(vocabularyEntries + imported)
            vocabularyTableView.reloadData()
            updateVocabularyStatus("Imported \(imported.count) entries")
        } catch {
            showAlert(title: "Vocabulary Import Failed", message: error.localizedDescription, style: .warning)
        }
    }

    @objc private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "DeskScribeVocabulary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try VocabularyCodec.exportData(entries: vocabularyEntries).write(to: url, options: .atomic)
            updateVocabularyStatus("Exported \(vocabularyEntries.count) entries")
        } catch {
            showAlert(title: "Vocabulary Export Failed", message: error.localizedDescription, style: .warning)
        }
    }

    private func updateVocabularyStatus(_ message: String? = nil) {
        vocabularyStatusLabel.stringValue = message ?? "\(vocabularyEntries.count) entries"
    }

    @objc private func refreshHistory() {
        historyEntries = TranscriptHistoryStore.load()
        historyTableView.reloadData()
        let stats = TranscriptHistoryStore.stats(for: historyEntries)
        statsLabel.stringValue = "Dictations: \(stats.dictationCount)   Words today: \(stats.todayWords)   This week: \(stats.weekWords)   All words: \(stats.totalWords)   Characters: \(stats.totalCharacters)"
    }

    @objc private func copySelectedTranscript() {
        let row = historyTableView.selectedRow
        guard row >= 0, row < historyEntries.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(historyEntries[row].text, forType: .string)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Transcript History?"
        alert.informativeText = "This removes locally saved transcript history and recalculates stats from an empty history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        TranscriptHistoryStore.clear()
        refreshHistory()
    }

    @objc private func captureHotKey() {
        hotKeyButton.title = "Press shortcut..."
        if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }
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
        if let preset = NativeONNXModelPresets.preset(titled: modelPresetPopup.titleOfSelectedItem) {
            modelRepoField.stringValue = preset.settings.repo
            modelFileField.stringValue = preset.settings.file
        }
        updateModelDetails()
        updateModelFieldsVisibility()
    }

    @objc private func showModelInfo() {
        showAlert(
            title: "Model Downloads",
            message: "DeskScribe downloads the selected model automatically the first time it is needed. Models are stored locally and reused later.",
            style: .informational
        )
    }

    private func updateModelDetails() {
        let preset = NativeONNXModelPresets.preset(titled: modelPresetPopup.titleOfSelectedItem) ?? NativeONNXModelPresets.defaultPreset
        modelLanguagesLabel.stringValue = preset.languages
        modelBestForLabel.stringValue = preset.bestFor
        modelNotesLabel.stringValue = preset.notes
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

    @objc private func resetDefaults() {
        capturedHotKey = AppSettings.defaultHotKey
        selectedTriggerMode = AppSettings.defaultTriggerMode
        hotKeyButton.title = AppSettings.displayName(for: capturedHotKey)
        triggerModePopup.selectItem(withTitle: selectedTriggerMode.displayName)
        modelRepoField.stringValue = AppSettings.defaultModel.repo
        modelFileField.stringValue = AppSettings.defaultModel.file
        vocabularyEntries = []
        vocabularyTableView.reloadData()
        updateVocabularyStatus()
        restorePasteboardCheckbox.state = AppSettings.defaultRestorePasteboardAfterPaste ? .on : .off
        modelPresetPopup.selectItem(withTitle: Self.defaultModelTitle)
        updateModelDetails()
        updateModelFieldsVisibility()
    }

    @objc private func cancel() {
        endCapture()
        window?.orderOut(nil)
    }

    @objc private func save() {
        let previousHotKey = AppSettings.hotKey
        let previousTriggerMode = AppSettings.triggerMode
        let previousModel = AppSettings.model

        let model: ModelSettings
        model = NativeONNXModelPresets.preset(titled: modelPresetPopup.titleOfSelectedItem)?.settings ?? AppSettings.defaultModel
        guard !model.repo.isEmpty, !model.file.isEmpty else { return }
        let vocabulary = VocabularySettings(words: VocabularyCodec.storedWords(from: vocabularyEntries))

        AppSettings.hotKey = capturedHotKey
        AppSettings.triggerMode = selectedTriggerMode
        AppSettings.model = model
        AppSettings.vocabulary = vocabulary
        AppSettings.restorePasteboardAfterPaste = restorePasteboardCheckbox.state == .on
        endCapture()
        if capturedHotKey != previousHotKey || selectedTriggerMode != previousTriggerMode || model != previousModel {
            onSave(capturedHotKey, selectedTriggerMode, model, vocabulary, AppSettings.restorePasteboardAfterPaste)
        }
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

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
