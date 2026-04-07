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

    private var cancellables: Set<AnyCancellable> = []
    private var bootstrapped = false

    init(
        shellState: ShellState,
        permissionsManager: PermissionsManager,
        hotkeyMonitor: HotkeyMonitor,
        captureManager: UtteranceCaptureManager,
        transcriptionService: UtteranceTranscriptionService
    ) {
        self.shellState = shellState
        self.permissionsManager = permissionsManager
        self.hotkeyMonitor = hotkeyMonitor
        self.captureManager = captureManager
        self.transcriptionService = transcriptionService
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
        syncShellState()
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
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.transcriptionService.transcribe(artifact)
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
