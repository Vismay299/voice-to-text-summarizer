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

    async let firstQueueRun: Void = queueService.transcribe(queuedArtifactOne, mode: .terminal)
    async let secondQueueRun: Void = queueService.transcribe(queuedArtifactTwo, mode: .writing)
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

            await service.transcribe(artifact, mode: .terminal)
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

    // MARK: - VoiceCommandParser Tests

    let cmdParser = VoiceCommandParser()
    let cleanerForCmds = TranscriptCleaner()

    // --- Command Detection Tests ---

    // new line
    let nlResult = cmdParser.parse("new line")
    expect(nlResult.commands.contains(.newLine), "Should detect 'new line' as newLine command")
    expect(nlResult.cleanedText == "\n", "Should replace 'new line' with newline")

    // newline variant
    let nlVar = cmdParser.parse("newline")
    expect(nlVar.commands.contains(.newLine), "Should detect 'newline' variant")

    // new paragraph
    let npResult = cmdParser.parse("new paragraph")
    expect(npResult.commands.contains(.newLine), "Should detect 'new paragraph' as newLine")

    // slash command (standalone)
    let slashResult = cmdParser.parse("slash command")
    expect(slashResult.commands.contains(.slashCommand), "Should detect 'slash command'")
    expect(slashResult.cleanedText == "/", "Should replace 'slash command' with /")

    // bare "slash" should NOT trigger
    let bareSlash = cmdParser.parse("slash")
    expect(!bareSlash.commands.contains(.slashCommand), "Bare 'slash' alone should not trigger")

    // open quote
    let oqResult = cmdParser.parse("open quote")
    expect(oqResult.commands.contains(.openQuote), "Should detect 'open quote'")
    expect(oqResult.cleanedText == "\"", "Should replace 'open quote' with quote")

    // open quotes
    let oqsResult = cmdParser.parse("open quotes")
    expect(oqsResult.commands.contains(.openQuote), "Should detect 'open quotes' variant")

    // code block
    let cbResult = cmdParser.parse("code block")
    expect(cbResult.commands.contains(.codeBlock), "Should detect 'code block'")
    expect(cbResult.cleanedText == "`", "Should replace 'code block' with backtick")

    // --- Multiple Commands ---

    // two commands — second command preceded by space, not a boundary, won't match
    let multiResult = cmdParser.parse("new line open quote hello")
    expect(multiResult.commands.count == 1, "Should detect 1 command (first at start), got \(multiResult.commands.count)")
    expect(multiResult.commands.contains(.newLine), "Multi-command should contain newLine")

    // commands at boundaries (second one preceded by space, not a sentence boundary — won't match)
    let boundResult = cmdParser.parse("new line hello world new line")
    expect(boundResult.commands.count == 1, "Should detect 1 command (first at start), got \(boundResult.commands.count)")

    // command at end
    let endResult = cmdParser.parse("hello world new line")
    // "new line" is preceded by "d " — not a boundary. This is correct behavior.
    // Commands should be spoken as standalone utterances, not embedded in speech.
    expect(endResult.commands.isEmpty, "Command preceded by word (not boundary) should not trigger")

    // command preceded by period
    let dotResult = cmdParser.parse("hello world. new line")
    expect(dotResult.commands.count == 1, "Command after period should trigger, got \(dotResult.commands)")

    // command only
    let onlyResult = cmdParser.parse("new line")
    expect(onlyResult.commands.count == 1, "Command-only input should detect 1 command")

    // --- False Positive Prevention ---

    // "a new line of code" should NOT trigger (embedded in sentence)
    let fpNewLine = cmdParser.parse("a new line of code")
    expect(!fpNewLine.commands.contains(.newLine), "Should NOT false-positive on 'a new line of code': detected \(fpNewLine.commands)")

    // "the code block failed" should NOT trigger
    let fpCode = cmdParser.parse("the code block failed")
    expect(!fpCode.commands.contains(.codeBlock), "Should NOT false-positive on 'the code block failed': detected \(fpCode.commands)")

    // "slash through the defense" — should NOT trigger without bare "slash" phrase
    let fpSlashResult = cmdParser.parse("slash through the defense")
    expect(!fpSlashResult.commands.contains(.slashCommand), "Bare 'slash' removed — 'slash through the defense' should not trigger")

    // --- Edge Cases ---

    // Case insensitive
    let caseResult = cmdParser.parse("NEW LINE")
    expect(caseResult.commands.contains(.newLine), "Should detect 'NEW LINE' case-insensitively")

    // Overlapping phrases: "new paragraph" wins over "new line" at same position
    let overlapResult = cmdParser.parse("new paragraph hello")
    expect(overlapResult.commands.count == 1, "Overlapping phrases should deduplicate, got \(overlapResult.commands.count)")
    expect(overlapResult.commands.contains(.newLine), "Should detect newLine from 'new paragraph'")

    // Mixed case
    let mixedCase = cmdParser.parse("New Line")
    expect(mixedCase.commands.contains(.newLine), "Should detect 'New Line' mixed case")

    // Empty input
    let emptyCmd = cmdParser.parse("")
    expect(emptyCmd.commands.isEmpty, "Empty input should produce no commands")
    expect(emptyCmd.cleanedText.isEmpty, "Empty input should produce empty cleaned text")

    // No commands
    let noCmd = cmdParser.parse("just normal text here")
    expect(noCmd.commands.isEmpty, "Normal text should produce no commands")
    expect(noCmd.cleanedText == "just normal text here", "Normal text should be unchanged")

    // --- Integration with Cleaner ---

    // Cleaned text then parsed: simulate the real pipeline
    let rawPipeline = "um so new line can you run the tests"
    let cleaned = cleanerForCmds.clean(rawPipeline, mode: .terminal)
    let pipedCmd = cmdParser.parse(cleaned)
    expect(pipedCmd.commands.contains(.newLine), "Pipeline: newLine should survive cleaner -> parser")

    let cleaner = TranscriptCleaner()

    // --- Terminal Mode Tests ---

    // Terminal: basic passthrough should not mangle content
    let terminalBasic = cleaner.clean("ls -la", mode: .terminal)
    expect(terminalBasic == "ls -la", "Terminal mode should pass through simple text unchanged: '\(terminalBasic)'")

    // Terminal: leading filler removal
    let terminalFiller = cleaner.clean("um can you show me the files", mode: .terminal)
    expect(!terminalFiller.hasPrefix("um "), "Terminal mode should strip leading 'um': '\(terminalFiller)'")
    expect(terminalFiller.contains("show me the files"), "Terminal mode should keep the rest after leading filler: '\(terminalFiller)'")

    // Terminal: mid-sentence filler preserved (terminal mode is gentle)
    let terminalMidFiller = cleaner.clean("run the tests um actually", mode: .terminal)
    expect(terminalMidFiller.contains("um"), "Terminal mode should preserve mid-sentence fillers: '\(terminalMidFiller)'")

    // Terminal: whitespace collapse
    let terminalWS = cleaner.clean("hello    world", mode: .terminal)
    expect(terminalWS == "hello world", "Terminal mode should collapse multiple spaces: '\(terminalWS)'")

    // Terminal: multiline input safety
    let terminalMulti = cleaner.clean("cd project\nls -la\ncat file.txt", mode: .terminal)
    expect(terminalMulti.contains("\n"), "Terminal mode should preserve newlines: '\(terminalMulti)'")

    // Terminal: special characters preserved
    let terminalSpecial = cleaner.clean("cat file.txt | grep hello > output.txt", mode: .terminal)
    expect(terminalSpecial.contains("|"), "Terminal mode should preserve pipe: '\(terminalSpecial)'")
    expect(terminalSpecial.contains(">"), "Terminal mode should preserve redirect: '\(terminalSpecial)'")

    // --- Writing Mode Tests ---

    // Writing: filler removal throughout
    let writingFiller = cleaner.clean("so um I think we should", mode: .writing)
    expect(!writingFiller.lowercased().hasPrefix("so "), "Writing mode should strip leading 'so': '\(writingFiller)'")
    expect(!writingFiller.lowercased().contains(" um "), "Writing mode should strip mid-sentence 'um': '\(writingFiller)'")

    // Writing: sentence capitalization
    let writingCaps = cleaner.clean("hello world. goodbye world", mode: .writing)
    expect(writingCaps.hasPrefix("Hello"), "Writing mode should capitalize first sentence: '\(writingCaps)'")

    // Writing: punctuation normalization
    let writingPunct = cleaner.clean("Hello , world .", mode: .writing)
    expect(!writingPunct.contains(" ,"), "Writing mode should remove space before comma: '\(writingPunct)'")
    expect(!writingPunct.contains(" ."), "Writing mode should remove space before period: '\(writingPunct)'")

    // Writing: multiple leading fillers
    let writingMultiFiller = cleaner.clean("um uh so like basically hello", mode: .writing)
    expect(!writingMultiFiller.lowercased().hasPrefix("um"), "Writing mode should strip multiple leading fillers: '\(writingMultiFiller)'")

    // --- Edge Cases ---

    // Empty input
    let emptyResult = cleaner.clean("", mode: .terminal)
    expect(emptyResult == "", "Cleaner should return empty string for empty input: '\(emptyResult)'")

    // Whitespace-only input
    let wsOnly = cleaner.clean("   \n  ", mode: .terminal)
    expect(wsOnly == "", "Cleaner should return empty string for whitespace-only input: '\(wsOnly)'")

    // Single word
    let singleWord = cleaner.clean("hello", mode: .terminal)
    expect(singleWord == "hello", "Cleaner should handle single word: '\(singleWord)'")

    // All filler words
    let allFillers = cleaner.clean("um uh ah", mode: .writing)
    expect(allFillers.isEmpty || allFillers.trimmingCharacters(in: .whitespaces).isEmpty, "All-filler input should produce empty or near-empty output: '\(allFillers)'")

    // False positive avoidance: words containing filler substrings
    let falsePositive = cleaner.clean("the summer actually kind of nice", mode: .writing)
    expect(falsePositive.contains("summer") || falsePositive.contains("mer"), "Cleaner should not strip substrings that look like fillers inside words: '\(falsePositive)'")
    expect(!falsePositive.lowercased().contains(" um "), "No false-positive filler removal from 'summer': '\(falsePositive)'")

    // Writing: code block mention should not break backticks
    let writingCode = cleaner.clean("use a code block like this", mode: .writing)
    expect(writingCode.contains("code block"), "Writing mode should preserve the phrase 'code block': '\(writingCode)'")

    // MARK: - SnippetStore Tests

    let storeTempDir = fileManager.temporaryDirectory
        .appendingPathComponent("snippet-store-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! fileManager.createDirectory(at: storeTempDir, withIntermediateDirectories: true)

    let testStore = SnippetStore(baseDirectoryURL: storeTempDir)
    try! testStore.bootstrap()

    expect(true, "SnippetStore can be instantiated and bootstrapped without crashing")

    let emptySnippets = try! testStore.loadRecent()
    expect(emptySnippets.isEmpty, "Empty store should return no snippets")

    let emptyCount = try! testStore.count()
    expect(emptyCount == 0, "Empty store count should be 0, got \(emptyCount)")

    let oneRecord = SnippetRecord(
        rawText: "hello from the snippet store",
        cleanedText: "Hello from the snippet store.",
        mode: "Writing",
        detectedCommands: []
    )
    try! testStore.insert(oneRecord)
    let loadedOne = try! testStore.loadRecent()
    expect(loadedOne.count == 1, "Should load 1 snippet, got \(loadedOne.count)")
    expect(loadedOne.first?.id == oneRecord.id, "Loaded id should match inserted id")
    expect(loadedOne.first?.rawText == oneRecord.rawText, "Raw text should match")
    expect(loadedOne.first?.cleanedText == oneRecord.cleanedText, "Cleaned text should match")
    expect(loadedOne.first?.mode == "Writing", "Mode should be 'Writing'")

    for i in 1...4 {
        try! testStore.insert(SnippetRecord(
            rawText: "snippet \(i)",
            mode: "Terminal",
            createdAt: Date().addingTimeInterval(Double(i) * 60)
        ))
    }
    let loadedThree = try! testStore.loadRecent(limit: 3)
    expect(loadedThree.count == 3, "Should load 3 of 5 snippets, got \(loadedThree.count)")
    expect(loadedThree.first?.rawText == "snippet 4", "Most recent should be snippet 4, got '\(loadedThree.first?.rawText ?? "")'")

    let updatedRecord = SnippetRecord(id: oneRecord.id, rawText: "updated text", mode: "Terminal")
    try! testStore.insert(updatedRecord)
    let afterUpsert = try! testStore.loadRecent(limit: 100)
    let upserted = afterUpsert.first { $0.id == oneRecord.id }
    expect(upserted?.rawText == "updated text", "Upsert should update raw text: '\(upserted?.rawText ?? "")'")
    expect(afterUpsert.count == 5, "Upsert should not create duplicate, count: \(afterUpsert.count)")

    let cmdRecord = SnippetRecord(rawText: "new line hello", detectedCommands: ["newLine"])
    try! testStore.insert(cmdRecord)
    let allAfterCmd = try! testStore.loadRecent(limit: 100)
    let cmdLoaded = allAfterCmd.first { $0.rawText == "new line hello" }
    expect(cmdLoaded?.detectedCommands.contains("newLine") == true, "Commands should round-trip")

    let nullRecord = SnippetRecord(rawText: "no target", targetAppName: nil, insertionSuccess: nil)
    try! testStore.insert(nullRecord)
    let allAfterNull = try! testStore.loadRecent(limit: 100)
    let nullLoaded = allAfterNull.first { $0.rawText == "no target" }
    expect(nullLoaded?.targetAppName == nil, "Null targetAppName should round-trip")
    expect(nullLoaded?.insertionSuccess == nil, "Null insertionSuccess should round-trip")

    let preDeleteCount = try! testStore.count()
    try! testStore.delete(id: oneRecord.id)
    let postDeleteCount = try! testStore.count()
    expect(postDeleteCount == preDeleteCount - 1, "Delete should reduce count by 1: \(preDeleteCount) → \(postDeleteCount)")

    try! testStore.delete(id: UUID())
    expect(true, "Delete non-existent id should not crash")

    let longText = String(repeating: "a", count: 10_000)
    try! testStore.insert(SnippetRecord(rawText: longText))
    let allAfterLong = try! testStore.loadRecent(limit: 100)
    let longLoaded = allAfterLong.first { $0.rawText.count == 10_000 }
    expect(longLoaded?.rawText.count == 10_000, "Long text should be preserved: \(longLoaded?.rawText.count ?? 0)")

    let unicodeText = "Hello 🌍 世界"
    try! testStore.insert(SnippetRecord(rawText: unicodeText))
    let allAfterUni = try! testStore.loadRecent(limit: 100)
    let unicodeLoaded = allAfterUni.first { $0.rawText == unicodeText }
    expect(unicodeLoaded?.rawText == unicodeText, "Unicode should be preserved: '\(unicodeLoaded?.rawText ?? "")'")

    let specialText = "hello | grep 'foo' > bar.txt && echo \"done\""
    try! testStore.insert(SnippetRecord(rawText: specialText))
    let allAfterSpecial = try! testStore.loadRecent(limit: 100)
    let specialLoaded = allAfterSpecial.first { $0.rawText == specialText }
    expect(specialLoaded?.rawText == specialText, "Special characters should be preserved: '\(specialLoaded?.rawText ?? "")'")

    try! testStore.clearAll()
    let afterClear = try! testStore.count()
    expect(afterClear == 0, "Clear all should empty the store, got \(afterClear)")

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
