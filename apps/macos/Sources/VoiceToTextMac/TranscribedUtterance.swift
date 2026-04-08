import Foundation

public struct TranscribedUtteranceSegment: Codable, Hashable, Identifiable, Sendable {
    public let index: Int
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let text: String
    public let confidence: Double?

    public init(
        index: Int,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        text: String,
        confidence: Double?
    ) {
        self.index = index
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.confidence = confidence
    }

    public var id: Int {
        index
    }
}

public struct RawTranscriptionResult: Codable, Hashable, Sendable {
    public let modelIdentifier: String
    public let language: String
    public let durationSeconds: TimeInterval
    public let text: String
    public let segments: [TranscribedUtteranceSegment]

    public init(
        modelIdentifier: String,
        language: String,
        durationSeconds: TimeInterval,
        text: String,
        segments: [TranscribedUtteranceSegment]
    ) {
        self.modelIdentifier = modelIdentifier
        self.language = language
        self.durationSeconds = durationSeconds
        self.text = text
        self.segments = segments
    }
}

public struct TranscribedUtterance: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let transcribedAt: Date
    public let sourceAudioURL: URL
    public let transcriptURL: URL
    public let modelIdentifier: String
    public let language: String
    public let durationSeconds: TimeInterval
    public let text: String
    public let segments: [TranscribedUtteranceSegment]
    public let cleanedText: String?
    public let mode: DictationMode?
    public let detectedCommands: [VoiceCommand]

    public init(
        id: UUID,
        capturedAt: Date,
        transcribedAt: Date,
        sourceAudioURL: URL,
        transcriptURL: URL,
        modelIdentifier: String,
        language: String,
        durationSeconds: TimeInterval,
        text: String,
        segments: [TranscribedUtteranceSegment],
        cleanedText: String? = nil,
        mode: DictationMode? = nil,
        detectedCommands: [VoiceCommand] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.transcribedAt = transcribedAt
        self.sourceAudioURL = sourceAudioURL
        self.transcriptURL = transcriptURL
        self.modelIdentifier = modelIdentifier
        self.language = language
        self.durationSeconds = durationSeconds
        self.text = text
        self.segments = segments
        self.cleanedText = cleanedText
        self.mode = mode
        self.detectedCommands = detectedCommands
    }

    /// The display text — cleaned if available, raw as fallback.
    public var displayText: String {
        cleanedText ?? text
    }

    public var transcriptPreview: String {
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 120 else {
            return trimmed
        }
        let preview = trimmed.prefix(120)
        return "\(preview)…"
    }
}

public enum TranscriptionState: Equatable {
    case idle
    case transcribing(utteranceID: UUID)
    case transcribed(TranscribedUtterance)
    case partial(partialText: String)
    case failed(String)
}
