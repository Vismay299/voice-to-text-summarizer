import Foundation
import SwiftUI

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

public enum DictationMode: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case writing = "Writing"

    public var id: String { rawValue }

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
    @Published public var selectedMode: DictationMode = .terminal
    @Published public var shellStatus: ShellStatus = .setupRequired
    @Published public var launchAtLoginEnabled = false
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
    @Published public var recentCapturedUtterances: [CapturedUtteranceArtifact] = []
    @Published public private(set) var currentCaptureState: UtteranceCaptureState = .idle
    @Published public private(set) var currentTranscriptionState: TranscriptionState = .idle
    @Published public var recentTranscribedUtterances: [TranscribedUtterance] = []
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

    public init() {}

    public var statusSummary: String {
        switch currentTranscriptionState {
        case .transcribing(let utteranceID):
            return "Transcribing utterance \(utteranceID.uuidString.prefix(8)) with large-v3."
        case .transcribed(let transcription):
            return "Transcript saved locally. \(transcription.segments.count) segments ready."
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
}
