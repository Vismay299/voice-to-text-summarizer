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
    private static let log = Logger(subsystem: "com.voicetotext.shell", category: "transcription-bridge")

    /// The persistent worker process.
    private let lock = NSLock()
    private var workerProcess: Process?
    private var workerStdin: FileHandle?
    private var workerStdout: FileHandle?
    private var workerStderr: Pipe?
    private var isReady = false

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
        lock.lock()
        guard workerProcess == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutable)
        process.arguments = [
            "python3",
            workerScriptURL.path,
            "--model", modelIdentifier,
            "--language", language,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONUNBUFFERED": "1"],
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

        lock.lock()
        workerProcess = process
        workerStdin = stdinPipe.fileHandleForWriting
        workerStdout = stdoutPipe.fileHandleForReading
        workerStderr = stderrPipe
        lock.unlock()

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

        lock.lock()
        isReady = true
        lock.unlock()
    }

    /// Stop the persistent worker. Safe to call multiple times.
    public func stopWorker() {
        stopWorkerSync()
    }

    private func stopWorkerSync() {
        lock.lock()
        let process = workerProcess
        let stdin = workerStdin
        workerProcess = nil
        workerStdin = nil
        workerStdout = nil
        workerStderr = nil
        isReady = false
        lock.unlock()

        // Close stdin to signal EOF → worker exits cleanly.
        stdin?.closeFile()
        process?.waitUntilExit()
        if let process {
            Self.log.info("Worker stopped (exit code \(process.terminationStatus))")
        }
    }

    /// Whether the worker is running and ready for requests.
    public var workerIsReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReady && workerProcess?.isRunning == true
    }

    // MARK: - Transcription

    public func transcribe(_ artifact: CapturedUtteranceArtifact) async throws -> RawTranscriptionResult {
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

        // Send request to worker stdin.
        lock.lock()
        let stdin = workerStdin
        lock.unlock()

        guard let stdin, let lineData = requestLine.data(using: .utf8) else {
            throw TranscriptionBridgeError.workerCrashed("Worker stdin unavailable")
        }

        stdin.write(lineData)

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

        return try decode(responseData)
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

                self.lock.lock()
                let stdout = self.workerStdout
                self.lock.unlock()

                guard let stdout else {
                    continuation.resume(throwing: TranscriptionBridgeError.workerCrashed("stdout unavailable"))
                    return
                }

                // Read byte-by-byte until newline. This is simple and correct
                // for line-delimited JSON where each response is one line.
                var buffer = Data()
                while true {
                    let byte = stdout.readData(ofLength: 1)
                    if byte.isEmpty {
                        // EOF — worker exited.
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
                }

                let line = String(decoding: buffer, as: UTF8.self)
                continuation.resume(returning: line)
            }
        }
    }

    /// Collect any available stderr output for diagnostics.
    private func collectStderr() -> String {
        lock.lock()
        let pipe = workerStderr
        lock.unlock()

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
