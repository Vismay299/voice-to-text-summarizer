import Combine
import Foundation
import VoiceToTextMac

@MainActor
final class DictationCoordinator {
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
        loadSnippets()

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
                if case .captured(let artifact) = captureState {
                    let mode = self.shellState.selectedMode
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.transcriptionService.transcribe(artifact, mode: mode)
                    }
                }
            }
            .store(in: &cancellables)

        transcriptionService.$transcriptionState
            .sink { [weak self] transcriptionState in
                self?.shellState.refreshTranscriptionState(transcriptionState)
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
        try? snippetStore.insert(record)
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
}
