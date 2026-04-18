import Foundation
import os.log

public protocol UtteranceTranscriptionBridging: Sendable {
    func transcribe(_ artifact: CapturedUtteranceArtifact) async throws -> RawTranscriptionResult
}

public enum TranscriptionBridgeError: LocalizedError {
    case missingScript
    case missingPythonRuntime(String)
    case processFailed(exitCode: Int32, stderr: String)
    case invalidResponse(String)
    case workerNotReady
    case workerCrashed(String)

    public var errorDescription: String? {
        switch self {
        case .missingScript:
            return "Unable to locate the bundled transcription worker script."
        case .missingPythonRuntime(let message):
            return message
        case .processFailed(let exitCode, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("No module named 'mlx_whisper'") || trimmed.contains("No module named \"mlx_whisper\"") {
                return "Python is available, but MLX Whisper is not installed. Run `python3 -m pip install -r services/asr-worker/requirements.txt` and relaunch the app."
            }
            if trimmed.isEmpty {
                return "The transcription worker exited with code \(exitCode)."
            }
            return "The transcription worker exited with code \(exitCode): \(trimmed)"
        case .invalidResponse(let reason):
            return "The transcription worker returned an invalid response: \(reason)"
        case .workerNotReady:
            return "The transcription worker has not finished loading the model."
        case .workerCrashed(let reason):
            return "The transcription worker crashed: \(reason)"
        }
    }
}

// MARK: - Persistent Worker Bridge

/// Series 13: Persistent Python transcription worker bridge.
///
/// Instead of spawning a new Python process per utterance (~200-500ms overhead),
/// this bridge keeps a single long-running Python process with the MLX Whisper
/// model preloaded in GPU memory. Requests are sent as JSON lines on stdin;
/// responses are read as JSON lines from stdout.
///
/// Lifecycle:
///   1. `startWorker()` — spawns the Python process, waits for `{"status":"ready"}`
///   2. `transcribe(_:)` — sends a JSON request, reads a JSON response
///   3. `stopWorker()` — closes stdin (triggers clean exit) and waits
public final class PythonLargeV3TranscriptionBridge: UtteranceTranscriptionBridging, @unchecked Sendable {
    private let pythonExecutable: String
    private let workerScriptURL: URL
    private let legacyScriptURL: URL
    private let modelIdentifier: String
    private let language: String
    private static let log = Logger(subsystem: "com.speakflow.shell", category: "transcription-bridge")

    /// The persistent worker process.
    /// Series 13 Review Fix: Replace NSLock with a serial dispatch queue
    /// because Swift 6 forbids NSLock.lock() from async contexts.
    private let stateQueue = DispatchQueue(label: "com.speakflow.worker-state", qos: .userInitiated)
    private let requestGate = WorkerRequestGate()
    private nonisolated(unsafe) var workerProcess: Process?
    private nonisolated(unsafe) var workerStdin: FileHandle?
    private nonisolated(unsafe) var workerStdout: FileHandle?
    private nonisolated(unsafe) var workerStderr: Pipe?
    private nonisolated(unsafe) var isReady = false

    public init(
        pythonExecutable: String = "/usr/bin/env",
        scriptURL: URL? = nil,
        modelIdentifier: String = "mlx-community/whisper-large-v3-turbo",
        language: String = "en"
    ) throws {
        // Resolve the persistent worker script.
        let resolvedWorkerURL = Bundle.module.url(forResource: "transcription_worker", withExtension: "py")
        guard let workerURL = resolvedWorkerURL else {
            throw TranscriptionBridgeError.missingScript
        }

        // Keep the legacy script URL for fallback reference.
        let resolvedLegacyURL = scriptURL ?? Bundle.module.url(forResource: "transcribe_utterance", withExtension: "py")
        guard let legacyURL = resolvedLegacyURL else {
            throw TranscriptionBridgeError.missingScript
        }

        self.pythonExecutable = pythonExecutable
        self.workerScriptURL = workerURL
        self.legacyScriptURL = legacyURL
        self.modelIdentifier = modelIdentifier
        self.language = language
    }

    // MARK: - Worker Lifecycle

    /// Start the persistent Python worker and wait for model warmup.
    /// Call this once at app startup (e.g., from DictationCoordinator).
    public func startWorker() async throws {
        var alreadyRunning: Bool = false
        stateQueue.sync { alreadyRunning = workerProcess != nil }
        guard !alreadyRunning else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutable)
        process.arguments = [
            "python3",
            workerScriptURL.path,
            "--model", modelIdentifier,
            "--language", language,
        ]
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extendedPath = "/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:\(existingPath)"
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONUNBUFFERED": "1", "PATH": extendedPath],
            uniquingKeysWith: { _, new in new }
        )

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw TranscriptionBridgeError.processFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        stateQueue.sync {
            workerProcess = process
            workerStdin = stdinPipe.fileHandleForWriting
            workerStdout = stdoutPipe.fileHandleForReading
            workerStderr = stderrPipe
        }

        Self.log.info("Worker process started (pid \(process.processIdentifier)). Waiting for model warmup...")

        // Wait for the {"status":"ready"} line from the worker.
        let readyLine = try await readLine()
        guard let readyData = readyLine.data(using: .utf8),
              let readyJSON = try? JSONSerialization.jsonObject(with: readyData) as? [String: Any],
              readyJSON["status"] as? String == "ready" else {
            let stderr = collectStderr()
            stopWorkerSync()
            throw TranscriptionBridgeError.processFailed(
                exitCode: -1,
                stderr: "Worker did not report ready. Got: \(readyLine). Stderr: \(stderr)"
            )
        }

        let warmupMs = readyJSON["warmup_ms"] as? Int ?? 0
        Self.log.info("Worker ready (model warmup: \(warmupMs)ms)")

        stateQueue.sync { isReady = true }
    }

    /// Stop the persistent worker. Safe to call multiple times.
    public func stopWorker() {
        stopWorkerSync()
    }

    private func stopWorkerSync() {
        var process: Process?
        var stdin: FileHandle?
        stateQueue.sync {
            process = workerProcess
            stdin = workerStdin
            workerProcess = nil
            workerStdin = nil
            workerStdout = nil
            workerStderr = nil
            isReady = false
        }

        // Close stdin to signal EOF → worker exits cleanly.
        stdin?.closeFile()
        process?.waitUntilExit()
        if let process {
            Self.log.info("Worker stopped (exit code \(process.terminationStatus))")
        }
    }

    /// Whether the worker is running and ready for requests.
    public var workerIsReady: Bool {
        var ready = false
        stateQueue.sync { ready = isReady && workerProcess?.isRunning == true }
        return ready
    }

    // MARK: - Transcription

    public func transcribe(_ artifact: CapturedUtteranceArtifact) async throws -> RawTranscriptionResult {
        await requestGate.acquire()
        defer {
            Task {
                await requestGate.release()
            }
        }

        // If the worker isn't ready, try to start it on demand.
        if !workerIsReady {
            Self.log.warning("Worker not ready, starting on demand...")
            try await startWorker()
        }

        // Guard again after potential startup.
        guard workerIsReady else {
            throw TranscriptionBridgeError.workerNotReady
        }

        let request: [String: String] = [
            "input": artifact.fileURL.path,
            "utterance_id": artifact.id.uuidString,
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              var requestLine = String(data: requestData, encoding: .utf8) else {
            throw TranscriptionBridgeError.invalidResponse("Failed to encode request JSON")
        }
        requestLine += "\n"

        // Send request to worker stdin (synchronized to prevent interleaved writes).
        var stdin: FileHandle?
        stateQueue.sync { stdin = workerStdin }
        let lineData = requestLine.data(using: .utf8)
        if let stdin, let lineData {
            stdin.write(lineData)
        }

        guard stdin != nil, lineData != nil else {
            throw TranscriptionBridgeError.workerCrashed("Worker stdin unavailable")
        }

        // Read response line from worker stdout.
        let responseLine = try await readLine()

        guard let responseData = responseLine.data(using: .utf8) else {
            throw TranscriptionBridgeError.invalidResponse("Empty response from worker")
        }

        // Check for worker-level errors.
        if let errorJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let errorMsg = errorJSON["error"] as? String {
            throw TranscriptionBridgeError.workerCrashed(errorMsg)
        }

        // Validate response utterance_id matches request.
        if let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let responseID = responseJSON["utterance_id"] as? String,
           responseID != artifact.id.uuidString {
            throw TranscriptionBridgeError.invalidResponse(
                "Response ID mismatch: expected \(artifact.id.uuidString), got \(responseID)"
            )
        }

        return try decode(responseData)
    }

    // MARK: - Idle Warmup Ping

    /// Run a silent-clip transcription through the worker to keep model
    /// weights resident in memory and the Metal/MLX GPU context warm.
    /// macOS will compress the 800MB of model weights under App Nap after
    /// a few minutes idle; this ping prevents that so the next real
    /// dictation doesn't pay a decompression/page-in cost.
    ///
    /// Non-blocking: if a user dictation is already holding the request
    /// gate, the ping is dropped rather than queued. Keeping pings out
    /// of the queue guarantees a timer fire can never delay real work.
    public func ping() async throws {
        let acquired = await requestGate.tryAcquire()
        guard acquired else { return }
        defer {
            Task {
                await requestGate.release()
            }
        }

        guard workerIsReady else {
            throw TranscriptionBridgeError.workerNotReady
        }

        let requestLine = "{\"ping\":true}\n"
        var stdin: FileHandle?
        stateQueue.sync { stdin = workerStdin }
        guard let stdin, let data = requestLine.data(using: .utf8) else {
            throw TranscriptionBridgeError.workerCrashed("Worker stdin unavailable")
        }
        stdin.write(data)

        let responseLine = try await readLine()
        guard let responseData = responseLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw TranscriptionBridgeError.invalidResponse("Malformed ping response: \(responseLine)")
        }
        if let errorMsg = json["error"] as? String {
            throw TranscriptionBridgeError.workerCrashed(errorMsg)
        }
        if json["pong"] as? Bool != true {
            throw TranscriptionBridgeError.invalidResponse("Ping missing pong: \(responseLine)")
        }
    }

    // MARK: - Line Reading

    /// Read one newline-terminated line from the worker's stdout.
    /// Runs on a background thread to avoid blocking the main actor.
    private func readLine() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TranscriptionBridgeError.workerCrashed("Bridge deallocated"))
                    return
                }

                var stdout: FileHandle?
                self.stateQueue.sync { stdout = self.workerStdout }

                guard let stdout else {
                    continuation.resume(throwing: TranscriptionBridgeError.workerCrashed("stdout unavailable"))
                    return
                }

                // Read byte-by-byte until newline. This is simple and correct
                // for line-delimited JSON where each response is one line.
                let maxLineLength = 10_000_000 // 10 MB safety limit
                var buffer = Data()
                while true {
                    let byte = stdout.readData(ofLength: 1)
                    if byte.isEmpty {
                        // EOF — worker exited. Mark as not ready so subsequent
                        // calls to transcribe() will attempt a restart.
                        self.stateQueue.sync {
                            self.isReady = false
                            self.workerProcess = nil
                            self.workerStdin = nil
                            self.workerStdout = nil
                        }

                        let stderr = self.collectStderr()
                        continuation.resume(throwing: TranscriptionBridgeError.workerCrashed(
                            "Worker exited unexpectedly. Stderr: \(stderr)"
                        ))
                        return
                    }
                    if byte[0] == UInt8(ascii: "\n") {
                        break
                    }
                    buffer.append(byte)
                    if buffer.count > maxLineLength {
                        continuation.resume(throwing: TranscriptionBridgeError.invalidResponse(
                            "Response line exceeded \(maxLineLength) bytes"
                        ))
                        return
                    }
                }

                let line = String(decoding: buffer, as: UTF8.self)
                continuation.resume(returning: line)
            }
        }
    }

    /// Collect any available stderr output for diagnostics.
    private func collectStderr() -> String {
        var pipe: Pipe?
        stateQueue.sync { pipe = workerStderr }
        guard let pipe else { return "" }
        let data = pipe.fileHandleForReading.availableData
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response Decoding

    private func decode(_ data: Data) throws -> RawTranscriptionResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let payload = try decoder.decode(PythonTranscriptionResponse.self, from: data)
            return RawTranscriptionResult(
                modelIdentifier: payload.modelIdentifier,
                language: payload.language,
                durationSeconds: payload.durationSeconds,
                text: payload.text,
                segments: payload.segments.map {
                    TranscribedUtteranceSegment(
                        index: $0.index,
                        startSeconds: $0.startSeconds,
                        endSeconds: $0.endSeconds,
                        text: $0.text,
                        confidence: $0.confidence
                    )
                }
            )
        } catch {
            let body = String(decoding: data, as: UTF8.self)
            throw TranscriptionBridgeError.invalidResponse(body.isEmpty ? error.localizedDescription : body)
        }
    }

    deinit {
        stopWorkerSync()
    }
}

private actor WorkerRequestGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Non-blocking acquire. Returns true if the gate was free and is now held;
    /// false if the gate was busy (caller should drop the work).
    func tryAcquire() -> Bool {
        guard !isHeld else { return false }
        isHeld = true
        return true
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

public struct UnavailableTranscriptionBridge: UtteranceTranscriptionBridging {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    public func transcribe(_ artifact: CapturedUtteranceArtifact) async throws -> RawTranscriptionResult {
        throw TranscriptionBridgeError.missingPythonRuntime(message)
    }
}

private struct PythonTranscriptionResponse: Codable {
    struct Segment: Codable {
        let index: Int
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let text: String
        let confidence: Double?
    }

    let modelIdentifier: String
    let language: String
    let durationSeconds: TimeInterval
    let text: String
    let segments: [Segment]
}
