import SwiftUI

public struct HistoryView: View {
    @EnvironmentObject private var shellState: ShellState

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local History")
                .font(.title2.weight(.semibold))

            Text("Capture artifacts and transcriptions are stored locally. Snippet history and resend flows will arrive later when insertion lands.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                if !shellState.recentTranscribedUtterances.isEmpty {
                    Section("Recent transcriptions") {
                        ForEach(shellState.recentTranscribedUtterances) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
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
                    }
                }

                if !shellState.recentCapturedUtterances.isEmpty {
                    Section("Recent capture artifacts") {
                        ForEach(shellState.recentCapturedUtterances) { artifact in
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
                    }
                }

                Section("Snippet history placeholder") {
                    ForEach(shellState.snippetHistory) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.mode.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(item.mode == .terminal ? .blue : .green)
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
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 420)
    }
}
