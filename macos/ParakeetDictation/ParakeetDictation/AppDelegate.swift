import AppKit
import AVFoundation
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenuItem = NSMenuItem(title: "Status: Launching", action: nil, keyEquivalent: "")
    private let log = DebugLog.shared
    private let overlay = TranscriptOverlay()
    private let audioRecorder = AudioRecorder()

    private var worker: WorkerManager?
    private var hotKeyMonitor: HotKeyMonitor?
    private var previousApp: NSRunningApplication?
    private var preferencesWindowController: PreferencesWindowController?
    private var isRecording = false
    private var isTranscribing = false
    private var hotKeyActive = false
    private var hotKeyRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("application did finish launching")
        setupMenu()

        guard let repoRoot = resolveRepoRoot() else {
            log.error("repo root not found")
            setStatus("Error: repo root not found")
            return
        }
        log.info("repo root: \(repoRoot.path)")

        let worker = WorkerManager(repoRoot: repoRoot, model: AppSettings.model)
        worker.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleWorkerState(state)
            }
        }
        self.worker = worker
        worker.start()

        let monitor = HotKeyMonitor(
            hotKey: AppSettings.hotKey,
            onPress: { [weak self] in DispatchQueue.main.async { self?.beginRecording() } },
            onRelease: { [weak self] in DispatchQueue.main.async { self?.finishRecording() } }
        )
        hotKeyMonitor = monitor

        startHotKeyMonitor(promptForAccessibility: true)
        startHotKeyRetryTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("application will terminate")
        hotKeyRetryTimer?.invalidate()
        worker?.stop()
        hotKeyMonitor?.stop()
    }

    private func setupMenu() {
        if let image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "ParakeetDictation") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "Parakeet"
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check Permissions", action: #selector(checkPermissions), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Debug Log", action: #selector(openDebugLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart Worker", action: #selector(restartWorker), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func resolveRepoRoot() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["PARAKEET_REPO_ROOT"] {
            log.info("using PARAKEET_REPO_ROOT=\(envPath)")
            return validRepoRoot(URL(fileURLWithPath: envPath))
        }

        if let plistPath = Bundle.main.object(forInfoDictionaryKey: "ParakeetRepoRoot") as? String {
            log.info("using ParakeetRepoRoot Info.plist value=\(plistPath)")
            return validRepoRoot(URL(fileURLWithPath: plistPath).standardizedFileURL)
        }

        return validRepoRoot(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    private func validRepoRoot(_ url: URL) -> URL? {
        let workerPath = url.appendingPathComponent("asr_worker.py").path
        let pythonPath = url.appendingPathComponent(".venv/bin/python").path
        guard FileManager.default.fileExists(atPath: workerPath), FileManager.default.isExecutableFile(atPath: pythonPath) else {
            log.warning("invalid repo root candidate=\(url.path), worker exists=\(FileManager.default.fileExists(atPath: workerPath)), python executable=\(FileManager.default.isExecutableFile(atPath: pythonPath))")
            return nil
        }
        return url
    }

    private func handleWorkerState(_ state: WorkerState) {
        guard !isRecording && !isTranscribing else { return }

        switch state {
        case .loading:
            log.info("worker state: loading")
            setStatus("Loading ASR worker")
        case .ready:
            log.info("worker state: ready")
            setStatus(hotKeyActive ? "Ready - hold \(AppSettings.displayName(for: AppSettings.hotKey))" : "Error: accessibility permission needed")
        case .failed(let message):
            log.error("worker state: failed: \(message)")
            setStatus("Error: \(message)")
        }
    }

    private func startHotKeyMonitor(promptForAccessibility: Bool) {
        guard !hotKeyActive else { return }

        let trusted = accessibilityTrusted(prompt: promptForAccessibility)
        guard trusted else {
            log.error("accessibility trust missing; hotkey monitor not started")
            setStatus("Error: accessibility permission needed")
            return
        }

        hotKeyActive = hotKeyMonitor?.start() ?? false
        if hotKeyActive {
            log.info("hotkey monitor started for \(AppSettings.displayName(for: AppSettings.hotKey))")
            if worker?.isReady == true {
                setStatus("Ready - hold \(AppSettings.displayName(for: AppSettings.hotKey))")
            }
        } else {
            log.error("hotkey monitor start failed even though accessibility is trusted")
            setStatus("Error: hotkey monitor failed")
        }
    }

    private func startHotKeyRetryTimer() {
        hotKeyRetryTimer?.invalidate()
        hotKeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, !self.hotKeyActive else { return }
            if self.accessibilityTrusted(prompt: false) {
                self.log.info("accessibility is now trusted; retrying hotkey monitor")
                self.startHotKeyMonitor(promptForAccessibility: false)
            }
        }
    }

    private func beginRecording() {
        log.info("hotkey pressed")
        guard !isRecording && !isTranscribing else { return }

        guard worker?.isReady == true else {
            log.warning("recording ignored because worker is not ready")
            overlay.show("ASR worker is still loading...")
            overlay.hide(after: 1.2)
            return
        }

        ensureMicrophonePermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.log.error("microphone permission missing")
                self.setStatus("Error: microphone permission needed")
                self.overlay.show("Enable microphone permission for ParakeetDictation")
                self.overlay.hide(after: 2.0)
                return
            }

            do {
                self.previousApp = NSWorkspace.shared.frontmostApplication
                self.log.info("previous app: \(self.previousApp?.localizedName ?? "unknown")")
                try self.audioRecorder.start()
                self.isRecording = true
                self.log.info("recording started")
                self.setStatus("Recording")
                self.overlay.show("Listening...")
            } catch {
                self.log.error("recording start failed: \(error.localizedDescription)")
                self.setStatus("Error: \(error.localizedDescription)")
                self.overlay.show("Could not start recording")
                self.overlay.hide(after: 2.0)
            }
        }
    }

    private func finishRecording() {
        log.info("hotkey released")
        guard isRecording else { return }
        isRecording = false

        guard let wavURL = audioRecorder.stop() else {
            log.warning("recording stop returned no WAV URL")
            setStatus("Ready - hold \(AppSettings.displayName(for: AppSettings.hotKey))")
            overlay.hide(after: 0.2)
            return
        }
        log.info("recording stopped: \(wavURL.path)")

        isTranscribing = true
        setStatus("Transcribing")
        overlay.show("Transcribing...")

        worker?.transcribe(audioURL: wavURL) { [weak self] result in
            DispatchQueue.main.async {
                try? FileManager.default.removeItem(at: wavURL)
                self?.handleTranscription(result)
            }
        }
    }

    private func handleTranscription(_ result: Result<String, Error>) {
        isTranscribing = false

        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("transcription succeeded, characters=\(trimmed.count)")
            setStatus("Ready - hold \(AppSettings.displayName(for: AppSettings.hotKey))")

            guard !trimmed.isEmpty else {
                log.warning("transcription was empty")
                overlay.show("No transcript")
                overlay.hide(after: 1.2)
                return
            }

            overlay.show(trimmed)
            pasteIntoPreviousApp(trimmed)
            overlay.hide(after: 1.6)

        case .failure(let error):
            log.error("transcription failed: \(error.localizedDescription)")
            setStatus("Error: \(error.localizedDescription)")
            overlay.show("Transcription failed")
            overlay.hide(after: 2.0)
        }
    }

    private func pasteIntoPreviousApp(_ text: String) {
        guard accessibilityTrusted(prompt: true) else {
            log.error("paste blocked because accessibility permission is missing")
            setStatus("Error: accessibility permission needed")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        log.info("pasting transcript into app: \(previousApp?.localizedName ?? "unknown")")
        previousApp?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Self.sendCommandV()
        }
    }

    private func ensureMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func setStatus(_ text: String) {
        statusMenuItem.title = "Status: \(text)"
        statusItem.button?.toolTip = text
    }

    @objc private func checkPermissions() {
        let accessibility = accessibilityTrusted(prompt: true) ? "granted" : "missing"
        log.info("permission check: accessibility=\(accessibility)")
        if accessibility == "granted" {
            startHotKeyMonitor(promptForAccessibility: false)
        }
        ensureMicrophonePermission { [weak self] granted in
            self?.log.info("permission check: microphone=\(granted ? "granted" : "missing")")
            self?.overlay.show("Accessibility: \(accessibility)\nMicrophone: \(granted ? "granted" : "missing")")
            self?.overlay.hide(after: 2.5)
        }
    }

    @objc private func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openMicrophoneSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @objc private func openDebugLog() {
        NSWorkspace.shared.open(log.url)
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController { [weak self] hotKey, model in
                self?.applyPreferences(hotKey: hotKey, model: model)
            }
        }
        preferencesWindowController?.show()
    }

    private func applyPreferences(hotKey: HotKeySettings, model: ModelSettings) {
        log.info("preferences saved hotkey=\(AppSettings.displayName(for: hotKey)) model=\(model.repo) file=\(model.file)")
        hotKeyMonitor?.updateHotKey(hotKey)
        startHotKeyMonitor(promptForAccessibility: true)
        worker?.updateModel(model)
        handleWorkerState(worker?.isReady == true ? .ready : .loading)
    }

    @objc private func restartWorker() {
        log.info("manual worker restart requested")
        worker?.restart()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyCodeForV: CGKeyCode = 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
