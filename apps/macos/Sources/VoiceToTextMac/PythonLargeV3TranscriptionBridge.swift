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
            if trimmed.contains("No module named 'mlx_whisper'") || trimmed.contains("No module named \"mlx_whisper\"") {
                return "Python is available, but MLX Whisper is not installed. Run `python3 -m pip install -r services/asr-worker/requirements.txt` and relaunch the app."
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

/// Bridge to the bundled Python `mlx-whisper + large-v3` transcription worker.
/// Runs on Apple Silicon GPU via the MLX framework.
public final class PythonLargeV3TranscriptionBridge: UtteranceTranscriptionBridging, @unchecked Sendable {
    private let pythonExecutable: String
    private let scriptURL: URL
    private let modelIdentifier = "mlx-community/whisper-large-v3-mlx"
    private let language = "en"

    public init(
        pythonExecutable: String = "/usr/bin/env",
        scriptURL: URL? = nil
    ) throws {
        let resolvedScriptURL = scriptURL ?? Bundle.module.url(forResource: "transcribe_utterance", withExtension: "py")
        guard let scriptURL = resolvedScriptURL else {
            throw TranscriptionBridgeError.missingScript
        }

        self.pythonExecutable = pythonExecutable
        self.scriptURL = scriptURL
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
