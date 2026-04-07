import Foundation

public protocol UtteranceTranscriptionBridging: Sendable {
    func transcribe(_ artifact: CapturedUtteranceArtifact) async throws -> RawTranscriptionResult
}

public enum TranscriptionBridgeError: LocalizedError {
    case missingScript
    case missingPythonRuntime(String)
    case processFailed(exitCode: Int32, stderr: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingScript:
            return "Unable to locate the bundled transcription script."
        case .missingPythonRuntime(let message):
            return message
        case .processFailed(let exitCode, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("No module named 'faster_whisper'") || trimmed.contains("No module named \"faster_whisper\"") {
                return "Python is available, but the local ASR dependencies are missing. Run `python3 -m pip install -r services/asr-worker/requirements.txt` and relaunch the app."
            }
            if trimmed.isEmpty {
                return "The transcription script exited with code \(exitCode)."
            }
            return "The transcription script exited with code \(exitCode): \(trimmed)"
        case .invalidResponse(let reason):
            return "The transcription script returned an invalid response: \(reason)"
        }
    }
}

public final class PythonLargeV3TranscriptionBridge: UtteranceTranscriptionBridging, @unchecked Sendable {
    private let pythonExecutable: String
    private let scriptURL: URL
    private let modelIdentifier = "large-v3"
    private let language = "en"
    private let device = "cpu"
    private let computeType = "int8"
    private let beamSize = 5
    private let cpuThreads: Int
    private let numWorkers: Int

    public init(
        pythonExecutable: String = "/usr/bin/env",
        scriptURL: URL? = nil,
        cpuThreads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        numWorkers: Int = 1
    ) throws {
        let resolvedScriptURL = scriptURL ?? Bundle.module.url(forResource: "transcribe_utterance", withExtension: "py")
        guard let scriptURL = resolvedScriptURL else {
            throw TranscriptionBridgeError.missingScript
        }

        self.pythonExecutable = pythonExecutable
        self.scriptURL = scriptURL
        self.cpuThreads = cpuThreads
        self.numWorkers = numWorkers
        // Validation moved out of init to avoid blocking the main thread at launch.
        // The first transcribe() call will surface missing-dependency errors naturally.
    }

    public func transcribe(_ artifact: CapturedUtteranceArtifact) async throws -> RawTranscriptionResult {
        let result = try await runPython(
            arguments: [
                "python3",
                scriptURL.path,
                "--input",
                artifact.fileURL.path,
                "--utterance-id",
                artifact.id.uuidString,
                "--model",
                modelIdentifier,
                "--language",
                language,
                "--device",
                device,
                "--compute-type",
                computeType,
                "--beam-size",
                "\(beamSize)",
                "--cpu-threads",
                "\(cpuThreads)",
                "--num-workers",
                "\(numWorkers)",
            ]
        )

        return try decode(result.stdout)
    }

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

    private func runPython(arguments: [String]) async throws -> (stdout: Data, stderr: Data) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonExecutable)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["PYTHONUNBUFFERED": "1"],
                uniquingKeysWith: { _, new in new }
            )

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Read pipes BEFORE waitUntilExit to avoid deadlock when output
            // exceeds the OS pipe buffer (~64KB). The subprocess blocks on
            // write if the pipe is full and nobody is reading.
            DispatchQueue.global(qos: .userInitiated).async {
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: (stdout: stdoutData, stderr: stderrData))
                } else {
                    let stderr = String(decoding: stderrData, as: UTF8.self)
                    continuation.resume(throwing: TranscriptionBridgeError.processFailed(
                        exitCode: process.terminationStatus,
                        stderr: stderr
                    ))
                }
            }
        }
    }

    private static func validatePythonEnvironment(pythonExecutable: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutable)
        process.arguments = ["python3", "-c", "import faster_whisper"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONUNBUFFERED": "1"],
            uniquingKeysWith: { _, new in new }
        )

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw TranscriptionBridgeError.missingPythonRuntime(
                "python3 is unavailable. Install Python 3 and the local ASR dependencies before using dictation."
            )
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw TranscriptionBridgeError.processFailed(exitCode: process.terminationStatus, stderr: stderr)
        }
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
