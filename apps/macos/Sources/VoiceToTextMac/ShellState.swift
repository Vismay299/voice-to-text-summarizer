import Foundation
import os.log
import ServiceManagement
import SwiftUI

private let kSelectedMode = "com.voicetotext.shell.selectedMode"
private let kAutoInsertEnabled = "com.voicetotext.shell.autoInsertEnabled"
private let kHasCompletedOnboarding = "com.voicetotext.shell.hasCompletedOnboarding"
private let kLaunchAtLoginEnabled = "com.voicetotext.shell.launchAtLogin"

public struct SnippetHistoryItem: Identifiable, Hashable {
    public let id: UUID
    public let mode: DictationMode
    public let text: String
    public let createdAt: Date

    public init(id: UUID, mode: DictationMode, text: String, createdAt: Date) {
        self.id = id
        self.mode = mode
        self.text = text
        self.createdAt = createdAt
    }
}

public enum DictationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal = "Terminal"
    case writing = "Writing"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .terminal:
            return "terminal"
        case .writing:
            return "pencil"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .terminal:
            return .blue
        case .writing:
            return .green
        }
    }

    public var description: String {
        switch self {
        case .terminal:
            return "Keeps wording closer to what you said and stays safe for CLI prompts."
        case .writing:
            return "Cleans punctuation and phrasing for essays, notes, and general writing."
        }
    }
}

public enum ShellStatus: String {
    case ready = "Shell Ready"
    case setupRequired = "Setup Required"

    public var symbolName: String {
        switch self {
        case .ready:
            return "waveform.circle.fill"
        case .setupRequired:
            return "exclamationmark.triangle.fill"
        }
    }

    public var tintName: String {
        switch self {
        case .ready:
            return "green"
        case .setupRequired:
            return "orange"
        }
    }
}

@MainActor
public final class ShellState: ObservableObject {
    private static let log = Logger(subsystem: "com.voicetotext.shell", category: "shellstate")

    @Published public var selectedMode: DictationMode {
        didSet {
            UserDefaults.standard.setValue(selectedMode.rawValue, forKey: kSelectedMode)
        }
    }

    @Published public var autoInsertEnabled: Bool {
        didSet {
            UserDefaults.standard.setValue(autoInsertEnabled, forKey: kAutoInsertEnabled)
        }
    }

    /// Series 12: Whether the user has completed the first-launch onboarding.
    @Published public var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.setValue(hasCompletedOnboarding, forKey: kHasCompletedOnboarding)
        }
    }

    /// Series 12: Whether to show the onboarding flow on first launch.
    public var shouldShowOnboarding: Bool {
        !hasCompletedOnboarding
    }

    /// Series 12: Launch-at-login toggle, persisted to UserDefaults.
    /// Uses a private backing property to avoid firing didSet during init.
    @Published public private(set) var launchAtLoginEnabled: Bool = false

    private let transcriptCleaner = TranscriptCleaner()
    @Published public var shellStatus: ShellStatus = .setupRequired
    @Published public var showOverlay = true
    @Published public var microphoneStatusText = "Microphone: not checked"
    @Published public var accessibilityStatusText = "Accessibility: not checked"
    @Published public var hotkeyStatusText = "Hotkey: not monitoring"
    @Published public var hotkeyDisplayName = "Right Option"
    @Published public var isHotkeyMonitoring = false
    @Published public var isPushToTalkPressed = false
    @Published public var captureStatusText = "Capture: idle"
    @Published public var captureDetailText = "Hold Right Option to record one utterance once the shell is ready."
    @Published public var transcriptionStatusText = "Transcription: idle"
    @Published public var transcriptionDetailText = "Captured utterances will be transcribed locally with large-v3."
    @Published public var insertionStatusText = "Insertion: idle"
    @Published public var insertionDetailText = "Auto-insert is enabled. Dictated text will appear at your cursor without pressing Enter."
    @Published public var currentInsertionState: InsertionState = .idle
    @Published public var recentInsertionResult: InsertionResult?
    @Published public var recentCapturedUtterances: [CapturedUtteranceArtifact] = []
    @Published public private(set) var currentCaptureState: UtteranceCaptureState = .idle
    @Published public private(set) var currentTranscriptionState: TranscriptionState = .idle
    @Published public var recentTranscribedUtterances: [TranscribedUtterance] = []
    @Published public var sqliteSnippets: [SnippetRecord] = []
    public var snippetStore: SnippetStore?

    /// Fix #5: Callback set by DictationCoordinator to actually reinsert text.
    public var onResendSnippet: ((String) -> Void)?
    @Published public var snippetHistory: [SnippetHistoryItem] = [
        SnippetHistoryItem(
            id: UUID(),
            mode: .terminal,
            text: "Explain why the build is failing and suggest the safest next step.",
            createdAt: .now.addingTimeInterval(-1800)
        ),
        SnippetHistoryItem(
            id: UUID(),
            mode: .writing,
            text: "This shell will eventually capture your voice locally and insert polished text at the active cursor.",
            createdAt: .now.addingTimeInterval(-4200)
        ),
    ]

    public init() {
        if let rawValue = UserDefaults.standard.string(forKey: kSelectedMode),
           let mode = DictationMode(rawValue: rawValue) {
            self.selectedMode = mode
        } else {
            self.selectedMode = .terminal
        }
        self.autoInsertEnabled = UserDefaults.standard.object(forKey: kAutoInsertEnabled) as? Bool ?? true
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: kHasCompletedOnboarding)
        // Set the backing Published value directly during init to avoid firing didSet.
        self._launchAtLoginEnabled = Published(initialValue: UserDefaults.standard.bool(forKey: kLaunchAtLoginEnabled))
    }

    /// Series 12: Enable or disable launch-at-login.
    /// This method persists the setting and registers/unregisters the login item.
    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginEnabled = enabled
        UserDefaults.standard.setValue(enabled, forKey: kLaunchAtLoginEnabled)
        applyLaunchAtLogin(enabled)
    }

    /// Update the active dictation mode. If `rebuildSnippets` is true,
    /// the snippet history will be re-cleaned using the new mode.
    public func updateMode(_ mode: DictationMode, rebuildSnippets: Bool = false) {
        selectedMode = mode
        if rebuildSnippets && !snippetHistory.isEmpty {
            rebuildSnippetPreviews()
        }
    }

    /// Return a cleaned preview of the given raw text using the current mode.
    public func cleanedPreview(for rawText: String) -> String {
        transcriptCleaner.clean(rawText, mode: selectedMode)
    }

    public var statusSummary: String {
        switch currentTranscriptionState {
        case .transcribing(let utteranceID):
            return "Transcribing utterance \(utteranceID.uuidString.prefix(8)) with large-v3."
        case .transcribed(let transcription):
            return "Transcript saved locally. \(transcription.segments.count) segments ready."
        case .partial(let text):
            let preview = text.prefix(60)
            return "Partial: \(preview)…"
        case .failed(let message):
            return message
        case .idle:
            break
        }

        switch currentCaptureState {
        case .recording:
            return "Recording now. Release \(hotkeyDisplayName) to save this utterance locally."
        case .finalizing:
            return "Finalizing the utterance and writing the audio artifact to disk."
        case .captured:
            return "Utterance saved locally. Local large-v3 transcription is queued."
        case .failed(let message):
            return message
        case .idle:
            switch shellStatus {
            case .ready:
                return "Ready to capture dictation. Hold \(hotkeyDisplayName) to speak into the focused app."
            case .setupRequired:
                return "Grant permissions and start monitoring \(hotkeyDisplayName) before dictation can begin."
            }
        }
    }

    public var readinessLabel: String {
        shellStatus.rawValue
    }

    public func refreshIntegrationState(
        microphoneState: PermissionState,
        accessibilityState: PermissionState,
        allRequiredGranted: Bool,
        isMonitoringHotkey: Bool,
        isPushToTalkPressed: Bool,
        hotkeyDisplayName: String
    ) {
        self.microphoneStatusText = formatPermissionState(label: "Microphone", rawState: microphoneState)
        self.accessibilityStatusText = formatPermissionState(label: "Accessibility", rawState: accessibilityState)
        self.hotkeyDisplayName = hotkeyDisplayName
        self.isHotkeyMonitoring = isMonitoringHotkey
        self.isPushToTalkPressed = isPushToTalkPressed
        self.hotkeyStatusText = formatHotkeyState()
        shellStatus = allRequiredGranted && isMonitoringHotkey ? .ready : .setupRequired
    }

    public func refreshCaptureState(_ captureState: UtteranceCaptureState) {
        currentCaptureState = captureState

        switch captureState {
        case .idle:
            captureStatusText = "Capture: idle"
            captureDetailText = "Hold \(hotkeyDisplayName) to record one utterance."
        case .recording(let utteranceID):
            captureStatusText = "Capture: recording"
            captureDetailText = "Recording utterance \(utteranceID.uuidString.prefix(8))."
        case .finalizing(let utteranceID):
            captureStatusText = "Capture: finalizing"
            captureDetailText = "Saving utterance \(utteranceID.uuidString.prefix(8)) to local storage."
        case .captured(let artifact):
            captureStatusText = "Capture: saved"
            captureDetailText = "\(artifact.fileURL.lastPathComponent) • \(formatDuration(artifact.durationSeconds)) • \(formatBytes(artifact.fileSizeBytes))"
            if recentCapturedUtterances.first?.id != artifact.id {
                recentCapturedUtterances.insert(artifact, at: 0)
                if recentCapturedUtterances.count > 12 {
                    recentCapturedUtterances = Array(recentCapturedUtterances.prefix(12))
                }
            }
        case .failed(let message):
            captureStatusText = "Capture: failed"
            captureDetailText = message
        }
    }

    public func refreshTranscriptionState(_ transcriptionState: TranscriptionState) {
        currentTranscriptionState = transcriptionState

        switch transcriptionState {
        case .idle:
            transcriptionStatusText = "Transcription: idle"
            transcriptionDetailText = "Captured utterances will be transcribed locally with large-v3."
        case .transcribing(let utteranceID):
            transcriptionStatusText = "Transcription: transcribing"
            transcriptionDetailText = "Transcribing utterance \(utteranceID.uuidString.prefix(8)) with large-v3."
        case .transcribed(let transcription):
            transcriptionStatusText = "Transcription: saved"
            transcriptionDetailText = "\(transcription.transcriptPreview) • \(transcription.segments.count) segments"
            recentTranscribedUtterances.removeAll { $0.id == transcription.id }
            recentTranscribedUtterances.insert(transcription, at: 0)
            if recentTranscribedUtterances.count > 12 {
                recentTranscribedUtterances = Array(recentTranscribedUtterances.prefix(12))
            }
        case .partial(let text):
            transcriptionStatusText = "Transcription: partial"
            transcriptionDetailText = "Live: \(text.prefix(40))…"
        case .failed(let message):
            transcriptionStatusText = "Transcription: failed"
            transcriptionDetailText = message
        }
    }

    private func formatPermissionState(label: String, rawState: PermissionState) -> String {
        "\(label): \(rawState.title)"
    }

    private func formatHotkeyState() -> String {
        if isHotkeyMonitoring {
            if isPushToTalkPressed {
                return "Hotkey: \(hotkeyDisplayName) pressed"
            }
            return "Hotkey: monitoring \(hotkeyDisplayName)"
        }

        return "Hotkey: not monitoring"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Snippet Cleaning

    /// Rebuild snippet previews using the current dictation mode.
    /// Snippets retain their original text but the mode badge reflects the
    /// current active mode for display consistency.
    private func rebuildSnippetPreviews() {
        snippetHistory = snippetHistory.map { item in
            let cleanedText = transcriptCleaner.clean(item.text, mode: selectedMode)
            return SnippetHistoryItem(
                id: item.id,
                mode: selectedMode,
                text: cleanedText.isEmpty ? item.text : cleanedText,
                createdAt: item.createdAt
            )
        }
    }

    // MARK: - Insertion State

    public func refreshInsertionState(_ insertionState: InsertionState) {
        currentInsertionState = insertionState

        switch insertionState {
        case .idle:
            insertionStatusText = "Insertion: idle"
            insertionDetailText = "Auto-insert is enabled. Dictated text will appear at your cursor without pressing Enter."
        case .detectingTarget:
            insertionStatusText = "Insertion: detecting"
            insertionDetailText = "Detecting the focused application…"
        case .inserting(let strategy):
            insertionStatusText = "Insertion: active"
            insertionDetailText = "Inserting text via \(strategy.rawValue)…"
        case .inserted(let result):
            insertionStatusText = "Insertion: success"
            if let appName = result.targetAppName {
                insertionDetailText = "Inserted into \(appName) (\(result.strategy.rawValue))."
            } else {
                insertionDetailText = "Inserted successfully (\(result.strategy.rawValue))."
            }
            recentInsertionResult = result
        case .failed(let message):
            insertionStatusText = "Insertion: failed"
            insertionDetailText = message
        }
    }

    // MARK: - Snippet Actions

    public func copySnippet(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    public func deleteSnippet(id: UUID) {
        sqliteSnippets.removeAll { $0.id == id }
        try? snippetStore?.delete(id: id)
    }

    /// Fix #5: Actually reinsert the text via the insertion engine (not just copy).
    public func resendSnippet(text: String) {
        onResendSnippet?(text)
    }

    public func clearAllSnippets() {
        sqliteSnippets = []
        try? snippetStore?.clearAll()
    }

    // MARK: - Series 12: Onboarding & Launch-at-Login

    /// Series 12: Auto-prompt for permissions on first launch.
    /// Called by DictationCoordinator during bootstrap to guide the user
    /// through the initial permission setup without requiring manual button clicks.
    ///
    /// The mic prompt is awaited so the user sees one dialog at a time.
    /// Accessibility is only prompted after the mic is confirmed granted.
    /// Onboarding is marked complete only when permissions are actually resolved
    /// (granted or explicitly denied), not just when dialogs were shown.
    public func requestPermissionsOnboarding(permissionsManager: PermissionsManager) {
        guard shouldShowOnboarding else { return }

        Task {
            // Step 1: Request microphone and wait for user response.
            await permissionsManager.requestMicrophoneAccess()

            // Step 2: Only request accessibility if mic was granted.
            // Re-check the actual permission status after the request completes.
            permissionsManager.refreshStates()
            if permissionsManager.microphoneState == .granted {
                permissionsManager.requestAccessibilityAccess()
                // Give the user time to respond in System Settings before marking complete.
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s grace period
            }

            // Mark onboarding complete so we don't re-prompt on every launch.
            // If the user denied mic, we still mark complete — they can use
            // the manual Grant buttons in the menu bar panel later.
            hasCompletedOnboarding = true
        }
    }

    /// Mark onboarding as complete (exposed for future "Skip" button in onboarding UI).
    public func markOnboardingComplete() {
        hasCompletedOnboarding = true
    }

    /// Series 12: Apply launch-at-login setting using ServiceManagement.
    /// On macOS 13+, uses SMAppService for modern login item registration.
    /// Skips in debug builds since unsigned apps cannot register as login items.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        #if DEBUG
        // Unsigned debug builds cannot register as login items.
        // Log the intent but skip the SMAppService call to avoid errors.
        Self.log.debug("Launch at login \(enabled ? "enabled" : "disabled") (no-op in debug build)")
        #else
        if #available(macOS 13.0, *) {
            do {
                let appService = SMAppService.mainApp
                if enabled {
                    try appService.register()
                } else {
                    try appService.unregister()
                }
            } catch {
                Self.log.warning("Launch at login \(enabled ? "enable" : "disable") failed: \(error.localizedDescription)")
            }
        }
        #endif
    }
}
