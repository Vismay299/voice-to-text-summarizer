import Foundation

@MainActor
public final class UtteranceTranscriptionService: ObservableObject {
    @Published public private(set) var transcriptionState: TranscriptionState = .idle
    @Published public private(set) var recentTranscriptions: [TranscribedUtterance] = []

    private let bridge: UtteranceTranscriptionBridging
    private let store: TranscribedUtteranceStore
    private var queuedArtifacts: [CapturedUtteranceArtifact] = []
    private var isProcessingQueue = false
    private var activeArtifactID: UUID?
    private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        bridge: UtteranceTranscriptionBridging? = nil,
        store: TranscribedUtteranceStore = TranscribedUtteranceStore()
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
    }

    public func bootstrap() {
        do {
            recentTranscriptions = try store.loadRecent(limit: 12)
        } catch {
            recentTranscriptions = []
        }
    }

    public func transcribe(_ artifact: CapturedUtteranceArtifact) async {
        if recentTranscriptions.contains(where: { $0.id == artifact.id }) {
            return
        }

        if queuedArtifacts.contains(where: { $0.id == artifact.id }) || activeArtifactID == artifact.id {
            await waitForCompletion(of: artifact.id)
            return
        }

        queuedArtifacts.append(artifact)
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
            let nextArtifact = queuedArtifacts.removeFirst()
            activeArtifactID = nextArtifact.id
            transcriptionState = .transcribing(utteranceID: nextArtifact.id)

            do {
                let raw = try await bridge.transcribe(nextArtifact)
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
                    segments: raw.segments
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
