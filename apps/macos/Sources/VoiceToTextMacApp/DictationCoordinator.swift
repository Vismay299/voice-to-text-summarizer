import Combine
import Foundation
import os.log
import VoiceToTextMac

@MainActor
final class DictationCoordinator {
    private static let log = Logger(subsystem: "com.voicetotext.shell", category: "coordinator")
    private let shellState: ShellState
    private let permissionsManager: PermissionsManager
    private let hotkeyMonitor: HotkeyMonitor
    private let captureManager: UtteranceCaptureManager
    private let transcriptionService: UtteranceTranscriptionService
    private let insertionEngine: TextInsertionEngine
    private let snippetStore: SnippetStore

    private var cancellables: Set<AnyCancellable> = []
    private var bootstrapped = false
    private var lastTranscription: TranscribedUtterance?
    private var lastInsertionResult: InsertionResult?

    /// Series 13: Timer for partial, real-time transcription during recording.
    /// Fires every 2 seconds to transcribe the growing WAV file and show text live.
    private var partialTranscriptionTimer: Timer?
    private var currentRecordingUtteranceID: UUID?
    private var currentRecordingMode: DictationMode?

    init(
        shellState: ShellState,
        permissionsManager: PermissionsManager,
        hotkeyMonitor: HotkeyMonitor,
        captureManager: UtteranceCaptureManager,
        transcriptionService: UtteranceTranscriptionService,
        insertionEngine: TextInsertionEngine,
        snippetStore: SnippetStore
    ) {
        self.shellState = shellState
        self.permissionsManager = permissionsManager
        self.hotkeyMonitor = hotkeyMonitor
        self.captureManager = captureManager
        self.transcriptionService = transcriptionService
        self.insertionEngine = insertionEngine
        self.snippetStore = snippetStore
        bind()
    }

    func bootstrapIfNeeded() {
        guard !bootstrapped else {
            return
        }

        bootstrapped = true
        permissionsManager.refreshStates()
        hotkeyMonitor.startMonitoring()
        shellState.refreshCaptureState(captureManager.captureState)
        transcriptionService.bootstrap()
        shellState.refreshTranscriptionState(transcriptionService.transcriptionState)
        shellState.recentTranscribedUtterances = transcriptionService.recentTranscriptions

        // Bootstrap snippet store and load snippets.
        try? snippetStore.bootstrap()
        shellState.snippetStore = snippetStore

        // Fix #5: Wire resend callback so the UI actually reinserts text.
        shellState.onResendSnippet = { [weak self] text in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.shellState.refreshInsertionState(.detectingTarget)
                let result = await self.insertionEngine.insertText(text)
                self.shellState.refreshInsertionState(
                    result.success ? .inserted(result) : .failed(result.errorMessage ?? "Resend failed")
                )
            }
        }

        loadSnippets()

        // Series 12: Auto-prompt for permissions on first launch.
        if shellState.shouldShowOnboarding {
            shellState.requestPermissionsOnboarding(permissionsManager: permissionsManager)
        }

        // Series 13: Start the persistent transcription worker in the background.
        // Model preload happens here so the first dictation doesn't pay startup cost.
        Task {
            await transcriptionService.startWorker()
        }

        syncShellState()
    }

    private func loadSnippets() {
        if let snippets = try? snippetStore.loadRecent(limit: 50) {
            shellState.sqliteSnippets = snippets
        }
    }

    private func bind() {
        permissionsManager.$microphoneState
            .sink { [weak self] _ in
                self?.syncShellState()
            }
            .store(in: &cancellables)

        permissionsManager.$accessibilityState
            .sink { [weak self] _ in
                self?.syncShellState()
            }
            .store(in: &cancellables)

        hotkeyMonitor.$isMonitoring
            .sink { [weak self] isMonitoring in
                guard let self else { return }
                self.syncShellState()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.handleMonitoringChanged(isMonitoring)
                }
            }
            .store(in: &cancellables)

        hotkeyMonitor.$isPushToTalkPressed
            .removeDuplicates()
            .sink { [weak self] isPressed in
                guard let self else { return }
                self.syncShellState()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.handlePushToTalkChange(isPressed)
                }
            }
            .store(in: &cancellables)

        captureManager.$captureState
            .sink { [weak self] captureState in
                guard let self else { return }
                self.shellState.refreshCaptureState(captureState)
                if case .recording(let utteranceID) = captureState {
                    // Series 13: Start partial transcription timer when recording begins.
                    self.currentRecordingUtteranceID = utteranceID
                    self.currentRecordingMode = self.shellState.selectedMode
                    self.startPartialTranscriptionTimer()
                } else if case .captured(let artifact) = captureState {
                    // Stop the partial timer — final transcription will run shortly.
                    self.stopPartialTranscriptionTimer()
                    let mode = self.shellState.selectedMode
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.transcriptionService.transcribe(artifact, mode: mode)
                    }
                } else {
                    self.stopPartialTranscriptionTimer()
                }
            }
            .store(in: &cancellables)

        transcriptionService.$transcriptionState
            .sink { [weak self] transcriptionState in
                self?.shellState.refreshTranscriptionState(transcriptionState)
                // Series 13: Update live partial text for UI display.
                if case .partial(let text) = transcriptionState {
                    self?.shellState.currentPartialText = text
                } else if case .transcribed = transcriptionState {
                    // Clear partial text once the final transcription is ready.
                    self?.shellState.currentPartialText = ""
                }
            }
            .store(in: &cancellables)

        transcriptionService.$recentTranscriptions
            .sink { [weak self] transcriptions in
                self?.shellState.recentTranscribedUtterances = transcriptions
            }
            .store(in: &cancellables)

        // Auto-insert when transcription completes.
        transcriptionService.$transcriptionState
            .sink { [weak self] state in
                guard let self else { return }
                if case .transcribed(let transcription) = state {
                    self.lastTranscription = transcription
                    if self.shellState.autoInsertEnabled {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let textToInsert = transcription.displayText
                            if textToInsert.isEmpty { return }

                            self.shellState.refreshInsertionState(.detectingTarget)
                            let result = await self.insertionEngine.insertText(textToInsert)
                            self.lastInsertionResult = result
                            self.shellState.refreshInsertionState(
                                result.success ? .inserted(result) : .failed(result.errorMessage ?? "Insertion failed")
                            )

                            // Save to snippet store after insertion.
                            self.saveSnippet(transcription, insertionResult: result)
                        }
                    } else {
                        // Even without auto-insert, save the snippet.
                        self.saveSnippet(transcription, insertionResult: nil)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func saveSnippet(_ transcription: TranscribedUtterance, insertionResult: InsertionResult?) {
        let commands = transcription.detectedCommands.map { $0.rawValue }
        let record = SnippetRecord(
            id: transcription.id,
            rawText: transcription.text,
            cleanedText: transcription.cleanedText,
            mode: (transcription.mode ?? .terminal).rawValue,
            detectedCommands: commands,
            targetAppName: insertionResult?.targetAppName,
            insertionSuccess: insertionResult?.success,
            createdAt: transcription.capturedAt,
            updatedAt: Date()
        )
        do {
            try snippetStore.insert(record)
        } catch {
            Self.log.error("Failed to save snippet: \(error.localizedDescription)")
        }
        loadSnippets()
    }

    private func syncShellState() {
        shellState.refreshIntegrationState(
            microphoneState: permissionsManager.microphoneState,
            accessibilityState: permissionsManager.accessibilityState,
            allRequiredGranted: permissionsManager.allRequiredGranted,
            isMonitoringHotkey: hotkeyMonitor.isMonitoring,
            isPushToTalkPressed: hotkeyMonitor.isPushToTalkPressed,
            hotkeyDisplayName: hotkeyMonitor.hotkeyDisplayName
        )
    }

    private func handlePushToTalkChange(_ isPressed: Bool) async {
        guard permissionsManager.allRequiredGranted, hotkeyMonitor.isMonitoring else {
            return
        }

        if isPressed {
            await captureManager.startCapture()
        } else {
            await captureManager.stopCapture()
        }
    }

    private func handleMonitoringChanged(_ isMonitoring: Bool) async {
        guard !isMonitoring else {
            return
        }

        if case .recording = captureManager.captureState {
            await captureManager.stopCapture()
        }
    }

    // MARK: - Series 13: Partial Transcription Timer

    /// Starts a timer that transcribes the growing WAV file every 2 seconds while recording.
    /// Shows partial text live in the UI so the user sees speech appearing as they speak.
    private func startPartialTranscriptionTimer() {
        partialTranscriptionTimer?.invalidate()
        partialTranscriptionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let utteranceID = self.currentRecordingUtteranceID,
                      let mode = self.currentRecordingMode else { return }
                // Get the current recording file path from the capture manager's state.
                if case .recording = self.captureManager.captureState {
                    // Build a temporary artifact pointing to the in-progress WAV file.
                    let artifact = CapturedUtteranceArtifact(
                        id: utteranceID,
                        fileURL: try! self.captureManager.currentRecordingURL(),
                        createdAt: Date(),
                        durationSeconds: 0,
                        fileSizeBytes: 0
                    )
                    await self.transcriptionService.transcribePartial(artifact, mode: mode)
                }
            }
        }
    }

    private func stopPartialTranscriptionTimer() {
        partialTranscriptionTimer?.invalidate()
        partialTranscriptionTimer = nil
        currentRecordingUtteranceID = nil
        currentRecordingMode = nil
    }
}
