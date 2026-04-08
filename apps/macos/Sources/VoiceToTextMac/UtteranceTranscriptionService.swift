import Foundation

@MainActor
public final class UtteranceTranscriptionService: ObservableObject {
    @Published public private(set) var transcriptionState: TranscriptionState = .idle
    @Published public private(set) var recentTranscriptions: [TranscribedUtterance] = []

    private let bridge: UtteranceTranscriptionBridging
    private let store: TranscribedUtteranceStore
    private let cleaner: TranscriptCleaner
    private let commandParser: VoiceCommandParser
    private var queuedArtifacts: [(artifact: CapturedUtteranceArtifact, mode: DictationMode)] = []
    private var isProcessingQueue = false
    private var activeArtifactID: UUID?
    private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        bridge: UtteranceTranscriptionBridging? = nil,
        store: TranscribedUtteranceStore = TranscribedUtteranceStore(),
        cleaner: TranscriptCleaner = TranscriptCleaner(),
        commandParser: VoiceCommandParser = VoiceCommandParser()
    ) {
        if let bridge {
            self.bridge = bridge
        } else {
            self.bridge = (try? PythonLargeV3TranscriptionBridge())
                ?? UnavailableTranscriptionBridge(
                    message: "Local transcription dependencies are unavailable. Run `python3 -m pip install -r services/asr-worker/requirements.txt` and relaunch the app."
                )
        }
        self.store = store
        self.cleaner = cleaner
        self.commandParser = commandParser
    }

    /// Series 13: Start the persistent transcription worker (model preload).
    /// Call once at app startup to eliminate per-utterance process spawn overhead.
    public func startWorker() async {
        if let persistent = bridge as? PythonLargeV3TranscriptionBridge {
            try? await persistent.startWorker()
        }
    }

    /// Series 13: Stop the persistent transcription worker.
    public func stopWorker() {
        if let persistent = bridge as? PythonLargeV3TranscriptionBridge {
            persistent.stopWorker()
        }
    }

    public func bootstrap() {
        do {
            recentTranscriptions = try store.loadRecent(limit: 12)
        } catch {
            recentTranscriptions = []
        }
    }

    public func transcribe(_ artifact: CapturedUtteranceArtifact, mode: DictationMode) async {
        if recentTranscriptions.contains(where: { $0.id == artifact.id }) {
            return
        }

        if queuedArtifacts.contains(where: { $0.artifact.id == artifact.id }) || activeArtifactID == artifact.id {
            await waitForCompletion(of: artifact.id)
            return
        }

        queuedArtifacts.append((artifact, mode))
        await withCheckedContinuation { continuation in
            completionWaiters[artifact.id, default: []].append(continuation)
            startQueueIfNeeded()
        }
    }

    private func startQueueIfNeeded() {
        guard !isProcessingQueue else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.processQueue()
        }
    }

    private func processQueue() async {
        guard !isProcessingQueue else {
            return
        }

        isProcessingQueue = true
        defer {
            isProcessingQueue = false
            activeArtifactID = nil
        }

        while !queuedArtifacts.isEmpty {
            let item = queuedArtifacts.removeFirst()
            let nextArtifact = item.artifact
            let mode = item.mode
            activeArtifactID = nextArtifact.id
            transcriptionState = .transcribing(utteranceID: nextArtifact.id)

            do {
                let raw = try await bridge.transcribe(nextArtifact)
                let cleaned = cleaner.clean(raw.text, mode: mode)
                let commandResult = commandParser.parse(cleaned)
                let finalText = commandResult.cleanedText.isEmpty ? nil : commandResult.cleanedText
                let transcriptURL = try store.transcriptURL(for: nextArtifact.id)
                let transcription = TranscribedUtterance(
                    id: nextArtifact.id,
                    capturedAt: nextArtifact.createdAt,
                    transcribedAt: Date(),
                    sourceAudioURL: nextArtifact.fileURL,
                    transcriptURL: transcriptURL,
                    modelIdentifier: raw.modelIdentifier,
                    language: raw.language,
                    durationSeconds: raw.durationSeconds,
                    text: raw.text,
                    segments: raw.segments,
                    cleanedText: finalText,
                    mode: mode,
                    detectedCommands: commandResult.commands
                )
                try store.persist(transcription)
                recentTranscriptions.removeAll { $0.id == transcription.id }
                recentTranscriptions.insert(transcription, at: 0)
                if recentTranscriptions.count > 12 {
                    recentTranscriptions = Array(recentTranscriptions.prefix(12))
                }
                transcriptionState = .transcribed(transcription)
            } catch {
                transcriptionState = .failed(error.localizedDescription)
            }

            finishQueuedTranscription(for: nextArtifact.id)
            activeArtifactID = nil
        }
    }

    private func waitForCompletion(of artifactID: UUID) async {
        await withCheckedContinuation { continuation in
            completionWaiters[artifactID, default: []].append(continuation)
        }
    }

    private func finishQueuedTranscription(for artifactID: UUID) {
        let waiters = completionWaiters.removeValue(forKey: artifactID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
