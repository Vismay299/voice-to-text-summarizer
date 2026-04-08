import AVFoundation
import Foundation

public enum UtteranceCaptureState: Equatable {
    case idle
    case recording(utteranceID: UUID)
    case finalizing(utteranceID: UUID)
    case captured(CapturedUtteranceArtifact)
    case failed(String)
}

@MainActor
public final class UtteranceCaptureManager: ObservableObject {
    @Published public private(set) var captureState: UtteranceCaptureState = .idle
    @Published public private(set) var latestArtifact: CapturedUtteranceArtifact?

    private let artifactStore: UtteranceArtifactStore
    private let audioSettings: [String: Any]
    private var recorder: AVAudioRecorder?
    private var activeUtteranceID: UUID?
    private var activeUtteranceCreatedAt: Date?
    private var activeRecordingURL: URL?

    public init(
        artifactStore: UtteranceArtifactStore = UtteranceArtifactStore(),
        audioSettings: [String: Any]? = nil
    ) {
        self.artifactStore = artifactStore
        self.audioSettings = audioSettings ?? Self.defaultAudioSettings
    }

    public func startCapture() async {
        switch captureState {
        case .recording, .finalizing:
            return
        case .idle, .captured, .failed:
            break
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            captureState = .failed("Microphone permission is not granted.")
            return
        }

        let utteranceID = UUID()
        let createdAt = Date()

        do {
            let recordingURL = try artifactStore.recordingURL(for: utteranceID)
            try prepareFreshRecordingURL(recordingURL)

            let newRecorder = try AVAudioRecorder(url: recordingURL, settings: audioSettings)
            newRecorder.prepareToRecord()

            guard newRecorder.record() else {
                try? removeItem(at: recordingURL)
                captureState = .failed("Unable to start microphone recording.")
                return
            }

            recorder = newRecorder
            activeUtteranceID = utteranceID
            activeUtteranceCreatedAt = createdAt
            activeRecordingURL = recordingURL
            captureState = .recording(utteranceID: utteranceID)
        } catch {
            captureState = .failed(error.localizedDescription)
        }
    }

    public func stopCapture() async {
        switch captureState {
        case .idle, .finalizing, .captured, .failed:
            return
        case .recording:
            break
        }

        guard let recorder, let utteranceID = activeUtteranceID, let createdAt = activeUtteranceCreatedAt, let recordingURL = activeRecordingURL else {
            resetRecorderState()
            captureState = .idle
            return
        }

        captureState = .finalizing(utteranceID: utteranceID)
        // Capture duration BEFORE stop() — currentTime returns 0 after recording ends.
        let recordedDuration = max(0, recorder.currentTime)
        recorder.stop()

        do {
            let artifact = try artifactStore.finalizeArtifact(
                utteranceID: utteranceID,
                fileURL: recordingURL,
                createdAt: createdAt,
                durationSeconds: recordedDuration
            )

            latestArtifact = artifact
            captureState = .captured(artifact)
        } catch {
            captureState = .failed(error.localizedDescription)
        }

        resetRecorderState()
    }

    public func currentRecordingURL() throws -> URL {
        guard let url = activeRecordingURL else {
            throw NSError(domain: "com.voicetotext.capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active recording."])
        }
        return url
    }

    private func resetRecorderState() {
        recorder = nil
        activeUtteranceID = nil
        activeUtteranceCreatedAt = nil
        activeRecordingURL = nil
    }

    private func prepareFreshRecordingURL(_ recordingURL: URL) throws {
        let directory = recordingURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            try FileManager.default.removeItem(at: recordingURL)
        }
    }

    private func removeItem(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static let defaultAudioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
}
