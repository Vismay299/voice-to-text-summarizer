import Foundation

public struct CapturedUtteranceArtifact: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let createdAt: Date
    public let durationSeconds: TimeInterval
    public let fileSizeBytes: Int64

    public init(
        id: UUID,
        fileURL: URL,
        createdAt: Date,
        durationSeconds: TimeInterval,
        fileSizeBytes: Int64
    ) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes
    }
}

public struct UtteranceArtifactStore {
    private let fileManager: FileManager
    private let baseDirectoryURL: URL?
    private let appDirectoryName = "VoiceToTextMac"
    private let utterancesDirectoryName = "utterances"

    public init(fileManager: FileManager = .default, baseDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL
    }

    public func recordingURL(for utteranceID: UUID) throws -> URL {
        let directory = try utteranceDirectory(for: utteranceID)
        return directory.appendingPathComponent("utterance.wav", isDirectory: false)
    }

    public func finalizeArtifact(
        utteranceID: UUID,
        fileURL: URL,
        createdAt: Date,
        durationSeconds: TimeInterval
    ) throws -> CapturedUtteranceArtifact {
        let fileSizeBytes = try fileSizeBytes(for: fileURL)
        return CapturedUtteranceArtifact(
            id: utteranceID,
            fileURL: fileURL,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            fileSizeBytes: fileSizeBytes
        )
    }

    private func utteranceDirectory(for utteranceID: UUID) throws -> URL {
        let root = try applicationSupportRoot()
        let utterancesDirectory = root.appendingPathComponent(utterancesDirectoryName, isDirectory: true)
        let directory = utterancesDirectory.appendingPathComponent(utteranceID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private func applicationSupportRoot() throws -> URL {
        if let baseDirectoryURL {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            return baseDirectoryURL
        }

        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let appDirectory = supportRoot.appendingPathComponent(appDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true, attributes: nil)
        return appDirectory
    }

    private func fileSizeBytes(for fileURL: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return 0
    }
}
