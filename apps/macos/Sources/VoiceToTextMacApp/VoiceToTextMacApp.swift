import SwiftUI
import VoiceToTextMac

@main
struct VoiceToTextMacApp: App {
    @StateObject private var shellState: ShellState
    @StateObject private var permissionsManager: PermissionsManager
    @StateObject private var hotkeyMonitor: HotkeyMonitor
    @StateObject private var captureManager: UtteranceCaptureManager
    @StateObject private var transcriptionService: UtteranceTranscriptionService
    @StateObject private var insertionEngine: TextInsertionEngine

    private let coordinator: DictationCoordinator

    init() {
        let shellState = ShellState()
        let permissionsManager = PermissionsManager()
        let hotkeyMonitor = HotkeyMonitor()
        let captureManager = UtteranceCaptureManager()
        let transcriptionService = UtteranceTranscriptionService()
        let insertionEngine = TextInsertionEngine()

        _shellState = StateObject(wrappedValue: shellState)
        _permissionsManager = StateObject(wrappedValue: permissionsManager)
        _hotkeyMonitor = StateObject(wrappedValue: hotkeyMonitor)
        _captureManager = StateObject(wrappedValue: captureManager)
        _transcriptionService = StateObject(wrappedValue: transcriptionService)
        _insertionEngine = StateObject(wrappedValue: insertionEngine)

        let coordinator = DictationCoordinator(
            shellState: shellState,
            permissionsManager: permissionsManager,
            hotkeyMonitor: hotkeyMonitor,
            captureManager: captureManager,
            transcriptionService: transcriptionService,
            insertionEngine: insertionEngine
        )
        self.coordinator = coordinator

        Task { @MainActor in
            coordinator.bootstrapIfNeeded()
        }
    }

    var body: some Scene {
        MenuBarExtra("Voice Dictation", systemImage: shellState.shellStatus.symbolName) {
            MenuBarPanelView()
            .environmentObject(shellState)
            .environmentObject(permissionsManager)
            .environmentObject(hotkeyMonitor)
        }
        .menuBarExtraStyle(.window)

        Window("Snippet History", id: "history") {
            HistoryView()
            .environmentObject(shellState)
            .environmentObject(permissionsManager)
            .environmentObject(hotkeyMonitor)
        }
        .defaultSize(width: 560, height: 440)

        Settings {
            SettingsView()
            .environmentObject(shellState)
            .environmentObject(permissionsManager)
            .environmentObject(hotkeyMonitor)
        }
    }
}
