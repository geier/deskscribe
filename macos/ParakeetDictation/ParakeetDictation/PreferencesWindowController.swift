import AppKit

final class PreferencesWindowController: NSWindowController {
    private let hotKeyButton = NSButton(title: "", target: nil, action: nil)
    private let modelRepoField = NSTextField(string: "")
    private let modelFileField = NSTextField(string: "")
    private let modelPresetPopup = NSPopUpButton()
    private var capturedHotKey = AppSettings.hotKey
    private var captureMonitor: Any?
    private let onSave: (HotKeySettings, ModelSettings) -> Void

    init(onSave: @escaping (HotKeySettings, ModelSettings) -> Void) {
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ParakeetDictation Preferences"
        window.center()
        super.init(window: window)
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

        hotKeyButton.target = self
        hotKeyButton.action = #selector(captureHotKey)
        hotKeyButton.bezelStyle = .rounded

        stack.addArrangedSubview(row(label: "Hotkey", control: hotKeyButton))
        stack.addArrangedSubview(row(label: "Model", control: modelPresetPopup))
        stack.addArrangedSubview(row(label: "Repo", control: modelRepoField))
        stack.addArrangedSubview(row(label: "File", control: modelFileField))

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

        buttons.widthAnchor.constraint(equalToConstant: 420).isActive = true
        modelRepoField.widthAnchor.constraint(equalToConstant: 290).isActive = true
        modelFileField.widthAnchor.constraint(equalToConstant: 290).isActive = true
        hotKeyButton.widthAnchor.constraint(equalToConstant: 180).isActive = true
        modelPresetPopup.widthAnchor.constraint(equalToConstant: 290).isActive = true

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
        let model = AppSettings.model
        hotKeyButton.title = AppSettings.displayName(for: capturedHotKey)
        modelRepoField.stringValue = model.repo
        modelFileField.stringValue = model.file
        modelPresetPopup.selectItem(withTitle: model == AppSettings.defaultModel ? "primeline/parakeet-primeline" : "Custom")
    }

    @objc private func captureHotKey() {
        hotKeyButton.title = "Press shortcut..."
        if let captureMonitor {
            NSEvent.removeMonitor(captureMonitor)
        }

        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = AppSettings.modifiers(from: event)
            guard !modifiers.isEmpty else {
                self.hotKeyButton.title = "Use a modifier key"
                return nil
            }

            self.capturedHotKey = HotKeySettings(keyCode: CGKeyCode(event.keyCode), modifiers: modifiers)
            self.hotKeyButton.title = AppSettings.displayName(for: self.capturedHotKey)
            if let captureMonitor = self.captureMonitor {
                NSEvent.removeMonitor(captureMonitor)
                self.captureMonitor = nil
            }
            return nil
        }
    }

    @objc private func modelPresetChanged() {
        if modelPresetPopup.titleOfSelectedItem == "primeline/parakeet-primeline" {
            modelRepoField.stringValue = AppSettings.defaultModel.repo
            modelFileField.stringValue = AppSettings.defaultModel.file
        }
    }

    @objc private func resetDefaults() {
        capturedHotKey = AppSettings.defaultHotKey
        hotKeyButton.title = AppSettings.displayName(for: capturedHotKey)
        modelRepoField.stringValue = AppSettings.defaultModel.repo
        modelFileField.stringValue = AppSettings.defaultModel.file
        modelPresetPopup.selectItem(withTitle: "primeline/parakeet-primeline")
    }

    @objc private func cancel() {
        window?.orderOut(nil)
    }

    @objc private func save() {
        let model = ModelSettings(
            repo: modelRepoField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            file: modelFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !model.repo.isEmpty, !model.file.isEmpty else { return }

        AppSettings.hotKey = capturedHotKey
        AppSettings.model = model
        onSave(capturedHotKey, model)
        window?.orderOut(nil)
    }
}
