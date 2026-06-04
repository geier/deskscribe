import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct SavedPasteboardItem {
        let dataByType: [(NSPasteboard.PasteboardType, Data)]
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenuItem = NSMenuItem(title: "Status: Launching", action: nil, keyEquivalent: "")
    private let retryModelDownloadMenuItem = NSMenuItem(title: "Retry Model Download", action: #selector(retryModelDownload), keyEquivalent: "")
    private let log = DebugLog.shared
    private let overlay = TranscriptOverlay()
    private let audioRecorder = AudioRecorder()

    private var worker: TranscriptionRuntime?
    private var hotKeyMonitor: HotKeyMonitor?
    private var previousApp: NSRunningApplication?
    private var preferencesWindowController: PreferencesWindowController?
    private var isRecording = false
    private var isTranscribing = false
    private var hotKeyActive = false
    private var hotKeyRetryTimer: Timer?
    private var recordingStartedAt: Date?
    private var recordingID: UUID?
    private var partialTimer: Timer?
    private var partialRequestInFlight = false
    private var partialRequestStartedAt: Date?
    private var lastPartialText = ""
    private var finalTranscriptionID: UUID?
    private var pendingPasteWorkItem: DispatchWorkItem?
    private var pendingPasteboardRestoreWorkItem: DispatchWorkItem?
    private var isCapturingHotKey = false
    private var shouldSendReturnAfterPaste = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("application did finish launching")
        setupMenu()

#if DESKSCRIBE_NATIVE_ONNX
        #if DEBUG
        let repoRoot = resolveRepoRoot()
        if let repoRoot {
            log.info("development repo root: \(repoRoot.path)")
        } else {
            log.info("development repo root not found; native ONNX runtime will use installed model paths")
        }
        #else
        let repoRoot: URL? = nil
        log.info("release native ONNX runtime will use installed model paths")
        #endif
#else
        guard let repoRoot = resolveRepoRoot() else {
            log.error("repo root not found")
            setStatus("Error: repo root not found")
            return
        }
        log.info("repo root: \(repoRoot.path)")
#endif

        let worker = TranscriptionRuntimeFactory.make(repoRoot: repoRoot, model: AppSettings.model)
        worker.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleWorkerState(state)
            }
        }
        worker.onProgress = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log.info("transcription progress: \(message)")
                guard self.isTranscribing else {
                    self.setStatus(message)
                    return
                }
                if self.lastPartialText.isEmpty {
                    self.overlay.show("Finishing...")
                }
            }
        }
        self.worker = worker
        worker.start()

        let monitor = HotKeyMonitor(
            hotKey: AppSettings.hotKey,
            onPress: { [weak self] in DispatchQueue.main.async { self?.handleHotKeyPress() } },
            onRelease: { [weak self] in DispatchQueue.main.async { self?.handleHotKeyRelease() } },
            onEscape: { [weak self] in
                if Thread.isMainThread {
                    return self?.cancelDictation() ?? false
                }

                var handled = false
                DispatchQueue.main.sync {
                    handled = self?.cancelDictation() ?? false
                }
                return handled
            },
            onReturn: { [weak self] in
                if Thread.isMainThread {
                    return self?.handleReturnDuringDictation() ?? false
                }

                var handled = false
                DispatchQueue.main.sync {
                    handled = self?.handleReturnDuringDictation() ?? false
                }
                return handled
            }
        )
        hotKeyMonitor = monitor

        startHotKeyMonitor(promptForAccessibility: true)
        startHotKeyRetryTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("application will terminate")
        hotKeyRetryTimer?.invalidate()
        partialTimer?.invalidate()
        pendingPasteWorkItem?.cancel()
        pendingPasteWorkItem = nil
        pendingPasteboardRestoreWorkItem?.cancel()
        pendingPasteboardRestoreWorkItem = nil
        worker?.cancelPendingTranscriptions()
        if isRecording {
            audioRecorder.cancel()
        }
        isRecording = false
        isTranscribing = false
        finalTranscriptionID = nil
        recordingID = nil
        recordingStartedAt = nil
        partialRequestInFlight = false
        partialRequestStartedAt = nil
        Self.releaseSyntheticModifierKeys()
        worker?.stop()
        hotKeyMonitor?.stop()
    }

    private func setupMenu() {
        if let image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: AppVariant.displayName) {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = AppVariant.displayName
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About \(AppVariant.displayName)", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check Permissions", action: #selector(checkPermissions), keyEquivalent: ""))
        #if DESKSCRIBE_NATIVE_ONNX
        retryModelDownloadMenuItem.isHidden = true
        retryModelDownloadMenuItem.isEnabled = false
        menu.addItem(retryModelDownloadMenuItem)
        #endif
        menu.addItem(NSMenuItem(title: "Open Debug Log", action: #selector(openDebugLog), keyEquivalent: ""))

        #if DEBUG
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart Runtime", action: #selector(restartWorker), keyEquivalent: ""))
        menu.addItem(.separator())
        #endif

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func resolveRepoRoot() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["DESKSCRIBE_WORKER_ROOT"] {
            log.info("using DESKSCRIBE_WORKER_ROOT=\(envPath)")
            if let repoRoot = validRepoRoot(URL(fileURLWithPath: envPath)) {
                return repoRoot
            }
        }

        if let bundledWorkerURL = Bundle.main.resourceURL?.appendingPathComponent("Worker") {
            log.info("checking bundled worker path=\(bundledWorkerURL.path)")
            if let repoRoot = validRepoRoot(bundledWorkerURL) {
                return repoRoot
            }
        }

        if let plistPath = Bundle.main.object(forInfoDictionaryKey: "DeskScribeWorkerRoot") as? String {
            log.info("using DeskScribeWorkerRoot Info.plist value=\(plistPath)")
            return validRepoRoot(URL(fileURLWithPath: plistPath).standardizedFileURL)
        }

        return validRepoRoot(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    private func validRepoRoot(_ url: URL) -> URL? {
#if DESKSCRIBE_NATIVE_ONNX
        let modelPackage = NativeONNXModelPackage(
            directory: NativeONNXModelPackage.developmentDirectory(repoRoot: url)
        )
        do {
            try modelPackage.validate()
            return url
        } catch {
            log.warning("invalid repo root candidate=\(url.path), native ONNX model validation failed: \(error.localizedDescription)")
            return nil
        }
#else
        let workerPath = url.appendingPathComponent(AppVariant.workerScriptName).path
        let pythonPath = url.appendingPathComponent(".venv/bin/python").path
        guard FileManager.default.fileExists(atPath: workerPath), FileManager.default.isExecutableFile(atPath: pythonPath) else {
            log.warning("invalid repo root candidate=\(url.path), worker exists=\(FileManager.default.fileExists(atPath: workerPath)), python executable=\(FileManager.default.isExecutableFile(atPath: pythonPath))")
            return nil
        }
        return url
#endif
    }

    private func handleWorkerState(_ state: WorkerState) {
        guard !isRecording && !isTranscribing else { return }

        switch state {
        case .loading:
            log.info("worker state: loading")
            setStatus("Loading ASR worker")
            updateRetryModelDownloadMenu(isVisible: false, isEnabled: false)
        case .ready:
            log.info("worker state: ready")
            setStatus(hotKeyActive ? readyStatusText() : "Error: accessibility permission needed")
            updateRetryModelDownloadMenu(isVisible: false, isEnabled: false)
        case .failed(let message):
            log.error("worker state: failed: \(message)")
            setStatus("Error: \(message)")
            updateRetryModelDownloadMenu(isVisible: true, isEnabled: true)
        }
    }

    private func updateRetryModelDownloadMenu(isVisible: Bool, isEnabled: Bool) {
        #if DESKSCRIBE_NATIVE_ONNX
        retryModelDownloadMenuItem.isHidden = !isVisible
        retryModelDownloadMenuItem.isEnabled = isEnabled
        #endif
    }

    private func startHotKeyMonitor(promptForAccessibility: Bool) {
        guard !isCapturingHotKey else { return }
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
                setStatus(readyStatusText())
            }
        } else {
            log.error("hotkey monitor start failed even though accessibility is trusted")
            setStatus("Error: hotkey monitor failed")
        }
    }

    private func startHotKeyRetryTimer() {
        hotKeyRetryTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, !self.hotKeyActive, !self.isCapturingHotKey else { return }
            if self.accessibilityTrusted(prompt: false) {
                self.log.info("accessibility is now trusted; retrying hotkey monitor")
                self.startHotKeyMonitor(promptForAccessibility: false)
            }
        }
        hotKeyRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleHotKeyPress() {
        switch AppSettings.triggerMode {
        case .toggle:
            if isRecording {
                finishRecording(reason: "hotkey pressed")
            } else {
                beginRecording(reason: "hotkey pressed")
            }
        case .hold:
            beginRecording(reason: "hotkey pressed")
        }
    }

    private func handleHotKeyRelease() {
        guard AppSettings.triggerMode == .hold else { return }
        finishRecording(reason: "hotkey released")
    }

    private func handleReturnDuringDictation() -> Bool {
        if isRecording {
            shouldSendReturnAfterPaste = true
            finishRecording(reason: "return pressed")
            return true
        }

        if isTranscribing {
            shouldSendReturnAfterPaste = true
            return true
        }

        return false
    }

    private func beginRecording(reason: String) {
        log.info("recording requested: \(reason)")
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
                self.overlay.show("Enable microphone permission for \(AppVariant.displayName)")
                self.overlay.hide(after: 2.0)
                return
            }

            do {
                self.previousApp = NSWorkspace.shared.frontmostApplication
                self.log.info("previous app: \(self.previousApp?.localizedName ?? "unknown")")
                try self.audioRecorder.start()
                self.isRecording = true
                self.recordingStartedAt = Date()
                self.recordingID = UUID()
                self.lastPartialText = ""
                self.log.info("recording started")
                self.setStatus("Recording - Return submits, Escape cancels")
                self.overlay.show("Listening...")
                if AppVariant.supportsPartialTranscription {
                    self.startPartialTranscription()
                }
            } catch {
                self.log.error("recording start failed: \(error.localizedDescription)")
                self.setStatus("Error: \(error.localizedDescription)")
                self.overlay.show("Could not start recording")
                self.overlay.hide(after: 2.0)
            }
        }
    }

    private func finishRecording(reason: String) {
        log.info("finishing recording: \(reason)")
        guard isRecording else { return }
        isRecording = false
        partialTimer?.invalidate()
        partialTimer = nil
        recordingID = nil
        partialRequestInFlight = false
        partialRequestStartedAt = nil
        worker?.cancelPendingTranscriptions()
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        guard let wavURL = audioRecorder.stop() else {
            log.warning("recording stop returned no WAV URL")
            shouldSendReturnAfterPaste = false
            setStatus(readyStatusText())
            overlay.hide(after: 0.2)
            return
        }
        log.info("recording stopped: \(wavURL.path), duration=\(String(format: "%.2f", duration))s")

        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: wavURL)
            log.warning("recording ignored because it was too short")
            shouldSendReturnAfterPaste = false
            setStatus(readyStatusText())
            overlay.show(AppSettings.triggerMode == .hold ? "Hold to dictate" : "Press to dictate")
            overlay.hide(after: 1.0)
            return
        }

        isTranscribing = true
        let transcriptionID = UUID()
        finalTranscriptionID = transcriptionID
        setStatus("Transcribing")
        if lastPartialText.isEmpty {
            overlay.show("Finishing...")
        }

        let transcriptionStartedAt = Date()
        worker?.transcribe(audioURL: wavURL, vocabulary: AppSettings.vocabulary, priority: .final) { [weak self] result in
            DispatchQueue.main.async {
                try? FileManager.default.removeItem(at: wavURL)
                self?.log.info("final transcription completed in \(Self.formatDuration(Date().timeIntervalSince(transcriptionStartedAt)))")
                self?.handleTranscription(result, transcriptionID: transcriptionID)
            }
        }
    }

    private func cancelDictation() -> Bool {
        guard isRecording || isTranscribing || overlay.isVisible else { return false }

        log.info("dictation cancelled with Escape")
        let wasRecording = isRecording
        let wasActive = isRecording || isTranscribing
        isRecording = false
        isTranscribing = false
        finalTranscriptionID = nil
        partialRequestInFlight = false
        partialRequestStartedAt = nil
        worker?.cancelPendingTranscriptions()
        pendingPasteWorkItem?.cancel()
        pendingPasteWorkItem = nil
        pendingPasteboardRestoreWorkItem?.cancel()
        pendingPasteboardRestoreWorkItem = nil
        shouldSendReturnAfterPaste = false
        partialTimer?.invalidate()
        partialTimer = nil
        recordingID = nil
        recordingStartedAt = nil
        if wasRecording {
            audioRecorder.cancel()
        }

        setStatus(readyStatusText())
        if wasActive {
            overlay.show("Cancelled")
            overlay.hide(after: 0.8)
        } else {
            overlay.hide()
        }
        return true
    }

    private func startPartialTranscription() {
        partialTimer?.invalidate()
        guard let recordingID else { return }

        let timer = Timer(timeInterval: AppVariant.partialTranscriptionInterval, repeats: true) { [weak self] _ in
            self?.requestPartialTranscription(recordingID: recordingID)
        }
        partialTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        log.info("partial transcription timer started initialDelay=\(AppVariant.partialTranscriptionInitialDelay)s interval=\(AppVariant.partialTranscriptionInterval)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + AppVariant.partialTranscriptionInitialDelay) { [weak self] in
            self?.requestPartialTranscription(recordingID: recordingID)
        }
    }

    private func requestPartialTranscription(recordingID: UUID) {
        guard isRecording, self.recordingID == recordingID else {
            return
        }

        if partialRequestInFlight {
            let elapsed = partialRequestStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            if elapsed > 8.0 {
                log.warning("partial transcription request timed out after \(Self.formatDuration(elapsed)); allowing next preview")
                partialRequestInFlight = false
                partialRequestStartedAt = nil
            } else {
                log.info("partial transcription skipped; previous request still in flight for \(Self.formatDuration(elapsed))")
                return
            }
        }

        guard worker?.isReady == true else {
            log.info("partial transcription skipped; runtime not ready")
            return
        }

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard duration >= AppVariant.partialTranscriptionMinimumDuration else { return }

        partialRequestInFlight = true
        let partialStartedAt = Date()
        partialRequestStartedAt = partialStartedAt

#if DESKSCRIBE_NATIVE_ONNX
        guard let snapshotSamples = audioRecorder.snapshotSamples() else {
            partialRequestInFlight = false
            return
        }
        log.info("partial transcription request: in-memory samples=\(snapshotSamples.count), duration=\(String(format: "%.2f", duration))s")
        worker?.transcribe(samples: snapshotSamples, vocabulary: AppSettings.vocabulary, priority: .partialPreview) { [weak self] result in
            DispatchQueue.main.async {
                self?.handlePartialTranscriptionResult(result, recordingID: recordingID, startedAt: partialStartedAt)
            }
        }
#else
        guard let snapshotURL = audioRecorder.snapshot() else {
            partialRequestInFlight = false
            return
        }
        log.info("partial transcription request: \(snapshotURL.path), duration=\(String(format: "%.2f", duration))s")
        worker?.transcribe(audioURL: snapshotURL, vocabulary: AppSettings.vocabulary, priority: .partialPreview) { [weak self] result in
            DispatchQueue.main.async {
                try? FileManager.default.removeItem(at: snapshotURL)
                self?.handlePartialTranscriptionResult(result, recordingID: recordingID, startedAt: partialStartedAt)
            }
        }
#endif
    }

    private func handlePartialTranscriptionResult(_ result: Result<String, Error>, recordingID: UUID, startedAt: Date) {
        partialRequestInFlight = false
        partialRequestStartedAt = nil
        log.info("partial transcription completed in \(Self.formatDuration(Date().timeIntervalSince(startedAt)))")

        guard isRecording, self.recordingID == recordingID else {
            log.info("ignored stale partial transcription result")
            return
        }

        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != lastPartialText else { return }
            lastPartialText = trimmed
            log.info("partial transcription update, characters=\(trimmed.count)")
            overlay.show(trimmed)
        case .failure(let error):
            if case NativeONNXRuntimeError.transcriptionCancelled = error {
                log.info("partial transcription cancelled")
                return
            }
            log.warning("partial transcription failed: \(error.localizedDescription)")
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        String(format: "%.3fs", seconds)
    }

    private func handleTranscription(_ result: Result<String, Error>, transcriptionID: UUID) {
        guard finalTranscriptionID == transcriptionID else {
            log.info("ignored stale final transcription result")
            return
        }

        finalTranscriptionID = nil
        isTranscribing = false

        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("transcription succeeded, characters=\(trimmed.count)")
            setStatus(readyStatusText())

            guard !trimmed.isEmpty else {
                log.warning("transcription was empty")
                shouldSendReturnAfterPaste = false
                overlay.show("No transcript")
                overlay.hide(after: 1.2)
                return
            }

            overlay.hide()
            let sendReturnAfterPaste = shouldSendReturnAfterPaste
            shouldSendReturnAfterPaste = false
            pasteIntoPreviousApp(trimmed, sendReturnAfterPaste: sendReturnAfterPaste)

        case .failure(let error):
            shouldSendReturnAfterPaste = false
            log.error("transcription failed: \(error.localizedDescription)")
            setStatus("Error: \(error.localizedDescription)")
            overlay.show("Transcription failed")
            overlay.hide(after: 2.0)
        }
    }

    private func pasteIntoPreviousApp(_ text: String, sendReturnAfterPaste: Bool) {
        guard accessibilityTrusted(prompt: true) else {
            log.error("paste blocked because accessibility permission is missing")
            shouldSendReturnAfterPaste = false
            setStatus("Error: accessibility permission needed")
            return
        }

        let pasteboard = NSPasteboard.general
        let shouldRestorePasteboard = AppSettings.restorePasteboardAfterPaste
        let savedPasteboard = shouldRestorePasteboard ? Self.savePasteboard(pasteboard) : []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let transcriptChangeCount = pasteboard.changeCount

        log.info("pasting transcript into app: \(previousApp?.localizedName ?? "unknown")")
        let shouldResumeHotKeyMonitor = hotKeyActive
        suspendHotKeyMonitorForPaste()
        previousApp?.activate(options: [.activateIgnoringOtherApps])
        pendingPasteWorkItem?.cancel()
        pendingPasteboardRestoreWorkItem?.cancel()
        let pasteWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer {
                Self.releaseSyntheticModifierKeys()
                if shouldResumeHotKeyMonitor {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.resumeHotKeyMonitorAfterPaste()
                    }
                }
            }

            self.pendingPasteWorkItem = nil
            let didPaste: Bool
            if Self.sendCommandV() {
                self.log.info("paste shortcut sent")
                didPaste = true
            } else if let previousApp = self.previousApp, Self.performAccessibilityPaste(in: previousApp) {
                self.log.warning("paste completed via visible Accessibility menu fallback")
                didPaste = true
            } else {
                self.log.error("paste failed")
                didPaste = false
            }
            if sendReturnAfterPaste && didPaste {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    if Self.sendReturnKey() {
                        self.log.info("return key sent after paste")
                    } else {
                        self.log.error("return key after paste failed")
                    }
                }
            }
            if shouldRestorePasteboard {
                self.restorePasteboard(savedPasteboard, expectedChangeCount: transcriptChangeCount, transcriptText: text, after: 0.8)
            } else {
                self.log.info("pasteboard restore disabled; transcript remains on clipboard")
            }
        }
        pendingPasteWorkItem = pasteWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: pasteWorkItem)
    }

    private func restorePasteboard(_ savedPasteboard: [SavedPasteboardItem], expectedChangeCount: Int, transcriptText: String, after delay: TimeInterval) {
        let restoreWorkItem = DispatchWorkItem { [weak self] in
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == expectedChangeCount,
                  pasteboard.string(forType: .string) == transcriptText else {
                self?.log.info("skipped pasteboard restore because clipboard changed")
                return
            }

            Self.restorePasteboard(savedPasteboard, to: pasteboard)
            self?.pendingPasteboardRestoreWorkItem = nil
            self?.log.info("pasteboard restored after paste")
        }
        pendingPasteboardRestoreWorkItem = restoreWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: restoreWorkItem)
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

    private func readyStatusText() -> String {
        let hotKey = AppSettings.displayName(for: AppSettings.hotKey)
        switch AppSettings.triggerMode {
        case .toggle:
            return "Ready - press \(hotKey)"
        case .hold:
            return "Ready - hold \(hotKey)"
        }
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

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"

        let alert = NSAlert()
        alert.messageText = AppVariant.displayName
        alert.informativeText = "Version: \(version) (\(build))\nBundle ID: \(bundleID)\nGitHub: \(AppVariant.githubURL.absoluteString)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open GitHub")
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(AppVariant.githubURL)
        }
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                onSave: { [weak self] hotKey, triggerMode, model, vocabulary, restorePasteboard in
                    self?.applyPreferences(hotKey: hotKey, triggerMode: triggerMode, model: model, vocabulary: vocabulary, restorePasteboard: restorePasteboard)
                },
                onCheckPermissions: { [weak self] in
                    self?.checkPermissions()
                },
                onCaptureStarted: { [weak self] in
                    self?.suspendHotKeyMonitorForCapture()
                },
                onCaptureEnded: { [weak self] in
                    self?.resumeHotKeyMonitorAfterCapture()
                }
            )
        }
        preferencesWindowController?.show()
    }

    private func suspendHotKeyMonitorForCapture() {
        guard !isCapturingHotKey else { return }
        log.info("suspending hotkey monitor for shortcut capture")
        isCapturingHotKey = true
        hotKeyMonitor?.stop()
        hotKeyActive = false
    }

    private func resumeHotKeyMonitorAfterCapture() {
        guard isCapturingHotKey else { return }
        log.info("resuming hotkey monitor after shortcut capture")
        isCapturingHotKey = false
        startHotKeyMonitor(promptForAccessibility: false)
    }

    private func suspendHotKeyMonitorForPaste() {
        guard hotKeyActive else { return }
        log.info("suspending hotkey monitor for paste")
        hotKeyMonitor?.stop()
        hotKeyActive = false
    }

    private func resumeHotKeyMonitorAfterPaste() {
        guard !isCapturingHotKey else { return }
        log.info("resuming hotkey monitor after paste")
        startHotKeyMonitor(promptForAccessibility: false)
    }

    private func applyPreferences(hotKey: HotKeySettings, triggerMode: TriggerMode, model: ModelSettings, vocabulary: VocabularySettings, restorePasteboard: Bool) {
        log.info("preferences saved hotkey=\(AppSettings.displayName(for: hotKey)) triggerMode=\(triggerMode.rawValue) model=\(model.repo) file=\(model.file) vocabulary=\(vocabulary.words.count) restorePasteboard=\(restorePasteboard)")
        hotKeyMonitor?.updateHotKey(hotKey)
        startHotKeyMonitor(promptForAccessibility: true)
        worker?.updateModel(model)
        handleWorkerState(worker?.isReady == true ? .ready : .loading)
    }

    @objc private func restartWorker() {
        log.info("manual worker restart requested")
        worker?.restart()
    }

    @objc private func retryModelDownload() {
        log.info("model download retry requested")
        updateRetryModelDownloadMenu(isVisible: true, isEnabled: false)
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

    private static func sendCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        guard let keyCodeForV = keyCode(forCharacter: "v") else { return false }
        DebugLog.shared.info("sending paste shortcut using keyCode=\(keyCodeForV)")

        let commandKeyCode = CGKeyCode(55)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true)
        commandDown?.flags = .maskCommand
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: false)
        keyUp?.flags = .maskCommand
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        commandUp?.flags = []

        guard let commandDown, let keyDown, let keyUp, let commandUp else { return false }

        commandDown.post(tap: .cghidEventTap)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        return true
    }

    private static func sendReturnKey() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let returnKeyCode = CGKeyCode(36)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false)
        guard let keyDown, let keyUp else { return false }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func releaseSyntheticModifierKeys() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let modifierKeyCodes: [CGKeyCode] = [55, 54, 58, 61, 59, 62, 56, 60]
        DebugLog.shared.info("releasing synthetic modifier keys")
        for keyCode in modifierKeyCodes {
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            keyUp?.flags = []
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [SavedPasteboardItem] {
        pasteboard.pasteboardItems?.map { item in
            let dataByType = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return SavedPasteboardItem(dataByType: dataByType)
        } ?? []
    }

    private static func restorePasteboard(_ savedItems: [SavedPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !savedItems.isEmpty else { return }

        let restoredItems = savedItems.map { savedItem in
            let item = NSPasteboardItem()
            for (type, data) in savedItem.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }

    private static func performAccessibilityPaste(in app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = axElementAttribute(appElement, kAXMenuBarAttribute as CFString) else {
            DebugLog.shared.warning("could not read menu bar for \(app.localizedName ?? "unknown app")")
            return false
        }

        let menuBarItems = axChildren(of: menuBar)
        let editItems = menuBarItems.filter { item in
            let title = axStringAttribute(item, kAXTitleAttribute as CFString)?.lowercased() ?? ""
            return title == "edit" || title == "bearbeiten"
        }

        for menuBarItem in editItems + menuBarItems {
            AXUIElementPerformAction(menuBarItem, kAXPressAction as CFString)
            usleep(80_000)

            if let pasteItem = findPasteMenuItem(in: menuBarItem) ?? findPasteMenuItem(in: menuBar) {
                let result = AXUIElementPerformAction(pasteItem, kAXPressAction as CFString)
                return result == .success
            }
        }

        return false
    }

    private static func findPasteMenuItem(in element: AXUIElement) -> AXUIElement? {
        if isPasteMenuItem(element) {
            return element
        }

        for child in axChildren(of: element) {
            if let found = findPasteMenuItem(in: child) {
                return found
            }
        }

        return nil
    }

    private static func isPasteMenuItem(_ element: AXUIElement) -> Bool {
        let title = axStringAttribute(element, kAXTitleAttribute as CFString)?.lowercased() ?? ""
        if title == "paste" || title == "einsetzen" || title == "einfügen" {
            return true
        }

        if let command = axStringAttribute(element, kAXMenuItemCmdCharAttribute as CFString)?.lowercased(), command == "v" {
            return !title.contains("match") && !title.contains("style") && !title.contains("stil")
        }

        return false
    }

    private static func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func keyCode(forCharacter target: Character) -> CGKeyCode? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            DebugLog.shared.warning("could not read current keyboard layout; falling back to ANSI V key")
            return nil
        }

        let data = unsafeBitCast(layoutData, to: CFData.self)
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        let targetString = String(target).lowercased()

        for keyCode in UInt16(0)..<UInt16(128) {
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )

            guard status == noErr, length > 0 else { continue }
            let value = String(utf16CodeUnits: chars, count: length).lowercased()
            if value == targetString {
                return CGKeyCode(keyCode)
            }
        }

        DebugLog.shared.warning("could not find keycode for character '\(target)' in current keyboard layout")
        return nil
    }
}
