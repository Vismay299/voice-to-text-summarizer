import AVFoundation
import Foundation
@testable import VoiceToTextMac

func envFlag(_ name: String) -> Bool {
    ProcessInfo.processInfo.environment[name] == "1"
}

func runProcess(_ executableURL: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw NSError(
            domain: "VoiceToTextMacTests.Process",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "Process failed." : stderr]
        )
    }
}

final class BridgeProbe {
    private let lock = NSLock()
    private var _activeCount = 0
    private var _maxActiveCount = 0

    var maxActiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxActiveCount
    }

    func enter() {
        lock.lock()
        _activeCount += 1
        _maxActiveCount = max(_maxActiveCount, _activeCount)
        lock.unlock()
    }

    func exit() {
        lock.lock()
        _activeCount = max(0, _activeCount - 1)
        lock.unlock()
    }
}

final class FakeTranscriptionBridge: UtteranceTranscriptionBridging, @unchecked Sendable {
    let probe = BridgeProbe()

    func transcribe(_ artifact: CapturedUtteranceArtifact) async throws -> RawTranscriptionResult {
        probe.enter()
        defer { probe.exit() }

        try await Task.sleep(nanoseconds: 150_000_000)

        let suffix = artifact.id.uuidString.prefix(6)
        return RawTranscriptionResult(
            modelIdentifier: "large-v3",
            language: "en",
            durationSeconds: max(artifact.durationSeconds, 0.25),
            text: "artifact \(suffix)",
            segments: [
                TranscribedUtteranceSegment(
                    index: 0,
                    startSeconds: 0,
                    endSeconds: max(artifact.durationSeconds, 0.25),
                    text: "artifact \(suffix)",
                    confidence: 0.98
                )
            ]
        )
    }
}

Task { @MainActor in
    var failures: [String] = []

    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures.append(message)
        }
    }

    expect(PermissionState.microphone(from: .notDetermined) == .notDetermined, "Microphone .notDetermined should map to .notDetermined.")
    expect(PermissionState.microphone(from: .restricted) == .restricted, "Microphone .restricted should map to .restricted.")
    expect(PermissionState.microphone(from: .denied) == .denied, "Microphone .denied should map to .denied.")
    expect(PermissionState.microphone(from: .authorized) == .granted, "Microphone .authorized should map to .granted.")

    expect(PermissionState.accessibility(trusted: true) == .granted, "Trusted accessibility should map to .granted.")
    expect(PermissionState.accessibility(trusted: false) == .notDetermined, "Untrusted accessibility should map to .notDetermined.")

    let permissions = PermissionsManager(refreshImmediately: false)
    permissions.setStatesForTesting(microphone: .granted, accessibility: .granted)
    expect(permissions.allRequiredGranted, "Permission manager should report granted when both permissions are granted.")

    permissions.setStatesForTesting(microphone: .denied, accessibility: .granted)
    expect(!permissions.allRequiredGranted, "Permission manager should report not ready when one permission is missing.")

    let pressSnapshot = HotkeyEventSnapshot(
        keyCode: HotkeyEventInterpreter.rightOptionKeyCode,
        isRightOptionPressed: true
    )
    expect(HotkeyEventInterpreter.transition(for: pressSnapshot) == .pressed, "Right Option press should be recognized.")

    let releaseSnapshot = HotkeyEventSnapshot(
        keyCode: HotkeyEventInterpreter.rightOptionKeyCode,
        isRightOptionPressed: false
    )
    expect(HotkeyEventInterpreter.transition(for: releaseSnapshot) == .released, "Right Option release should be recognized.")

    let ignoredSnapshot = HotkeyEventSnapshot(
        keyCode: 58,
        isRightOptionPressed: true
    )
    expect(HotkeyEventInterpreter.transition(for: ignoredSnapshot) == .ignored, "Non-Right-Option key codes should be ignored.")

    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("voice-to-text-mac-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let artifactStore = UtteranceArtifactStore(baseDirectoryURL: temporaryRoot)
    let utteranceID = UUID()
    let recordingURL = try! artifactStore.recordingURL(for: utteranceID)
    expect(recordingURL.lastPathComponent == "utterance.wav", "Artifact store should create utterance.wav files.")
    expect(recordingURL.path.contains("utterances"), "Artifact store should place files under an utterances directory.")

    let testPayload = Data([0x01, 0x02, 0x03, 0x04])
    try! testPayload.write(to: recordingURL)
    let finalizedArtifact = try! artifactStore.finalizeArtifact(
        utteranceID: utteranceID,
        fileURL: recordingURL,
        createdAt: Date(timeIntervalSince1970: 0),
        durationSeconds: 1.25
    )
    expect(finalizedArtifact.fileSizeBytes == 4, "Artifact store should report the correct file size.")
    expect(finalizedArtifact.durationSeconds == 1.25, "Artifact store should preserve duration metadata.")

    let transcriptStore = TranscribedUtteranceStore(baseDirectoryURL: temporaryRoot)
    let transcriptURL = try! transcriptStore.transcriptURL(for: utteranceID)
    let persistedTranscription = TranscribedUtterance(
        id: utteranceID,
        capturedAt: Date(timeIntervalSince1970: 0),
        transcribedAt: Date(timeIntervalSince1970: 60),
        sourceAudioURL: recordingURL,
        transcriptURL: transcriptURL,
        modelIdentifier: "large-v3",
        language: "en",
        durationSeconds: 1.25,
        text: "hello from the local transcript store",
        segments: [
            TranscribedUtteranceSegment(
                index: 0,
                startSeconds: 0,
                endSeconds: 1.25,
                text: "hello from the local transcript store",
                confidence: 0.98
            )
        ]
    )
    try! transcriptStore.persist(persistedTranscription)
    let reloadedTranscriptions = try! transcriptStore.loadRecent(limit: 1)
    expect(reloadedTranscriptions.first?.id == persistedTranscription.id, "Transcript store should reload persisted transcripts.")
    expect(reloadedTranscriptions.first?.transcriptPreview.contains("hello") == true, "Transcript preview should preserve the text.")

    let queueBridge = FakeTranscriptionBridge()
    let queueService = UtteranceTranscriptionService(
        bridge: queueBridge,
        store: TranscribedUtteranceStore(baseDirectoryURL: temporaryRoot.appendingPathComponent("queue", isDirectory: true))
    )

    let queuedArtifactOne = CapturedUtteranceArtifact(
        id: UUID(),
        fileURL: recordingURL,
        createdAt: Date(),
        durationSeconds: 0.8,
        fileSizeBytes: 4
    )
    let queuedArtifactTwo = CapturedUtteranceArtifact(
        id: UUID(),
        fileURL: recordingURL,
        createdAt: Date(),
        durationSeconds: 0.9,
        fileSizeBytes: 4
    )

    async let firstQueueRun: Void = queueService.transcribe(queuedArtifactOne)
    async let secondQueueRun: Void = queueService.transcribe(queuedArtifactTwo)
    _ = await (firstQueueRun, secondQueueRun)

    let maxConcurrent = queueBridge.probe.maxActiveCount
    expect(maxConcurrent == 1, "Transcription service should serialize utterances instead of running bridge calls concurrently.")
    expect(queueService.recentTranscriptions.count == 2, "Transcription service should keep both queued transcription results.")

    if envFlag("VOICE_TO_TEXT_MACOS_SMOKE_CAPTURE") {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            fputs("SKIP: live capture smoke requested, but microphone permission is not granted for this executable.\n", stderr)
        } else {
            let smokeRoot = fileManager.temporaryDirectory
                .appendingPathComponent("voice-to-text-mac-smoke", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let smokeManager = UtteranceCaptureManager(
                artifactStore: UtteranceArtifactStore(baseDirectoryURL: smokeRoot)
            )

            await smokeManager.startCapture()
            try? await Task.sleep(nanoseconds: 700_000_000)
            await smokeManager.stopCapture()

            switch smokeManager.captureState {
            case .captured(let artifact):
                let exists = fileManager.fileExists(atPath: artifact.fileURL.path)
                expect(exists, "Smoke capture should leave a file on disk.")
                expect(artifact.fileSizeBytes > 0, "Smoke capture artifact should be non-empty.")
            case .failed(let message):
                failures.append("Smoke capture failed: \(message)")
            default:
                failures.append("Smoke capture did not produce a captured artifact.")
            }
        }
    }

    if envFlag("VOICE_TO_TEXT_MACOS_SMOKE_TRANSCRIBE") {
        do {
            let smokeRoot = fileManager.temporaryDirectory
                .appendingPathComponent("voice-to-text-mac-transcribe-smoke", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)

            let captureStore = UtteranceArtifactStore(baseDirectoryURL: smokeRoot)
            let utteranceID = UUID()
            let wavURL = try captureStore.recordingURL(for: utteranceID)
            let aiffURL = smokeRoot.appendingPathComponent("sample.aiff")

            try FileManager.default.createDirectory(
                at: smokeRoot,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try runProcess(
                URL(fileURLWithPath: "/usr/bin/say"),
                arguments: [
                    "-o", aiffURL.path,
                    "hello from voice to text"
                ]
            )
            try runProcess(
                URL(fileURLWithPath: "/usr/bin/afconvert"),
                arguments: [
                    aiffURL.path,
                    wavURL.path,
                    "-f", "WAVE",
                    "-d", "LEI16@16000"
                ]
            )

            let artifact = try captureStore.finalizeArtifact(
                utteranceID: utteranceID,
                fileURL: wavURL,
                createdAt: Date(),
                durationSeconds: 1.0
            )
            let transcriptionStore = TranscribedUtteranceStore(baseDirectoryURL: smokeRoot)
            let service = UtteranceTranscriptionService(
                store: transcriptionStore
            )

            await service.transcribe(artifact)
            guard case .transcribed(let transcription) = service.transcriptionState else {
                let detail: String
                if case .failed(let message) = service.transcriptionState {
                    detail = message
                } else {
                    detail = String(describing: service.transcriptionState)
                }
                failures.append("Smoke transcription did not finish successfully: \(detail)")
                throw NSError(domain: "VoiceToTextMacTests", code: 1)
            }

            let lowercased = transcription.text.lowercased()
            expect(lowercased.contains("hello"), "Smoke transcription should include the spoken greeting.")
        } catch {
            failures.append("Smoke transcription failed: \(error.localizedDescription)")
        }
    }

    if failures.isEmpty {
        print("VoiceToTextMac test runner passed.")
        exit(0)
    }

    for failure in failures {
        fputs("FAIL: \(failure)\n", stderr)
    }

    exit(1)
}

RunLoop.main.run()
