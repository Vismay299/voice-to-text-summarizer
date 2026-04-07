import Foundation

public final class TranscribedUtteranceStore {
    private let fileManager: FileManager
    private let baseDirectoryURL: URL?
    private let appDirectoryName = "VoiceToTextMac"
    private let utterancesDirectoryName = "utterances"

    public init(fileManager: FileManager = .default, baseDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL
    }

    public func transcriptURL(for utteranceID: UUID) throws -> URL {
        let directory = try utteranceDirectory(for: utteranceID)
        return directory.appendingPathComponent("transcript.json", isDirectory: false)
    }

    public func persist(_ transcription: TranscribedUtterance) throws {
        let transcriptURL = transcription.transcriptURL
        try fileManager.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(transcription)
        try data.write(to: transcriptURL, options: [.atomic])
    }

    public func loadRecent(limit: Int = 12) throws -> [TranscribedUtterance] {
        let root = try utterancesRoot()
        guard fileManager.fileExists(atPath: root.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let transcripts = urls.compactMap { directory -> TranscribedUtterance? in
            let transcriptURL = directory.appendingPathComponent("transcript.json", isDirectory: false)
            guard fileManager.fileExists(atPath: transcriptURL.path) else {
                return nil
            }

            do {
                let data = try Data(contentsOf: transcriptURL)
                return try decoder.decode(TranscribedUtterance.self, from: data)
            } catch {
                return nil
            }
        }

        return transcripts
            .sorted { $0.transcribedAt > $1.transcribedAt }
            .prefix(limit)
            .map { $0 }
    }

    private func utteranceDirectory(for utteranceID: UUID) throws -> URL {
        let root = try utterancesRoot()
        let directory = root.appendingPathComponent(utteranceID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private func utterancesRoot() throws -> URL {
        if let baseDirectoryURL {
            let utterancesDirectory = baseDirectoryURL
                .appendingPathComponent(utterancesDirectoryName, isDirectory: true)
            try fileManager.createDirectory(at: utterancesDirectory, withIntermediateDirectories: true, attributes: nil)
            return utterancesDirectory
        }

        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let appDirectory = supportRoot.appendingPathComponent(appDirectoryName, isDirectory: true)
        let utterancesDirectory = appDirectory.appendingPathComponent(utterancesDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: utterancesDirectory, withIntermediateDirectories: true, attributes: nil)
        return utterancesDirectory
    }
}
