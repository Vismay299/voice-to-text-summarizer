import SwiftUI

public struct HistoryView: View {
    @EnvironmentObject private var shellState: ShellState

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Local History")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !shellState.sqliteSnippets.isEmpty {
                    Button("Clear All") {
                        shellState.clearAllSnippets()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("Capture artifacts and transcriptions are stored locally.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                if !shellState.recentTranscribedUtterances.isEmpty {
                    Section("Recent transcriptions") {
                        ForEach(shellState.recentTranscribedUtterances) { item in
                            transcriptionRow(item)
                        }
                    }
                }

                if !shellState.recentCapturedUtterances.isEmpty {
                    Section("Recent capture artifacts") {
                        ForEach(shellState.recentCapturedUtterances) { artifact in
                            artifactRow(artifact)
                        }
                    }
                }

                if !shellState.sqliteSnippets.isEmpty {
                    Section("Snippets") {
                        ForEach(shellState.sqliteSnippets) { item in
                            sqliteSnippetRow(item)
                        }
                    }
                }

                if !shellState.snippetHistory.isEmpty {
                    Section("Snippet history (legacy)") {
                        ForEach(shellState.snippetHistory) { item in
                            snippetRow(item)
                        }
                    }
                }

                if shellState.recentTranscribedUtterances.isEmpty
                    && shellState.recentCapturedUtterances.isEmpty
                    && shellState.sqliteSnippets.isEmpty
                    && shellState.snippetHistory.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No history yet")
                            .font(.headline)
                        Text("Dictated text will appear here once you start using voice dictation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 40)
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 420)
    }

    // MARK: - Transcription Rows

    private func transcriptionRow(_ item: TranscribedUtterance) -> some View {
        let displayMode = item.mode ?? .terminal
        let displayText = item.displayText
        let hasCleanedVersion = item.cleanedText != nil && item.cleanedText != item.text.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                modeBadge(displayMode)

                Text(item.modelIdentifier)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(item.transcribedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.transcriptPreview)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if hasCleanedVersion {
                Divider()
                    .padding(.vertical, 2)

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(displayText)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Voice command badges
            if !item.detectedCommands.isEmpty {
                Divider()
                    .padding(.vertical, 2)

                HStack(spacing: 4) {
                    Text("Commands:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(item.detectedCommands) { cmd in
                        commandBadge(cmd)
                    }
                }
            }

            Text("\(item.language.uppercased()) • \(item.segments.count) segments • \(String(format: "%.2fs", item.durationSeconds))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(item.transcriptURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Artifact Rows

    private func artifactRow(_ artifact: CapturedUtteranceArtifact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(artifact.fileURL.lastPathComponent)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(artifact.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(artifact.fileURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("\(String(format: "%.2fs", artifact.durationSeconds)) • \(ByteCountFormatter.string(fromByteCount: artifact.fileSizeBytes, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Snippet Rows

    private func snippetRow(_ item: SnippetHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                modeBadge(item.mode)
                Spacer()
                Text(item.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.text)
                .font(.body)
        }
        .padding(.vertical, 4)
    }

    // MARK: - SQLite Snippet Rows

    private func sqliteSnippetRow(_ item: SnippetRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                modeBadge(DictationMode(rawValue: item.mode) ?? .terminal)

                if item.insertionSuccess == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    if let appName = item.targetAppName {
                        Text(appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if item.insertionSuccess == false {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
                Text(item.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.preview)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !item.detectedCommands.isEmpty {
                HStack(spacing: 4) {
                    Text("Commands:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(item.detectedCommands.compactMap { VoiceCommand(rawValue: $0) }, id: \.id) { cmd in
                        commandBadge(cmd)
                    }
                }
            }

            HStack(spacing: 6) {
                Button("Copy") {
                    shellState.copySnippet(item.displayText)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Resend") {
                    shellState.copySnippet(item.displayText)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    shellState.deleteSnippet(id: item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.7))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Mode Badge

    private func modeBadge(_ mode: DictationMode) -> some View {
        HStack(spacing: 4) {
            Image(systemName: mode.iconName)
                .font(.caption.weight(.semibold))
            Text(mode.rawValue)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(mode.badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(mode.badgeColor.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Command Badge

    private func commandBadge(_ command: VoiceCommand) -> some View {
        Text(command.displayName.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.indigo)
            .clipShape(Capsule())
    }
}
