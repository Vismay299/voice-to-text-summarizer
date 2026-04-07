import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject private var shellState: ShellState
    @EnvironmentObject private var permissionsManager: PermissionsManager
    @EnvironmentObject private var hotkeyMonitor: HotkeyMonitor

    public init() {}

    public var body: some View {
        Form {
            Section("Shell") {
                Toggle("Show floating status overlay", isOn: $shellState.showOverlay)
                Toggle("Launch at login", isOn: $shellState.launchAtLoginEnabled)
                    .disabled(true)
            }

            Section("Dictation Mode") {
                Picker("Mode", selection: $shellState.selectedMode) {
                    ForEach(DictationMode.allCases) { mode in
                        HStack {
                            Image(systemName: mode.iconName)
                            Text(mode.rawValue)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Circle()
                        .fill(shellState.selectedMode.badgeColor)
                        .frame(width: 8, height: 8)

                    Text(shellState.selectedMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }

            Section("Permissions and Hotkey") {
                Label(shellState.microphoneStatusText, systemImage: "mic")
                Label(shellState.accessibilityStatusText, systemImage: "accessibility")
                Label(shellState.hotkeyStatusText, systemImage: "command")

                Text("Hotkey: \(shellState.hotkeyDisplayName)")
                    .font(.callout.weight(.semibold))

                HStack {
                    Button("Refresh Status") {
                        refreshShellState()
                    }

                    Button("Grant Microphone") {
                        Task {
                            await permissionsManager.requestMicrophoneAccess()
                            refreshShellState()
                        }
                    }

                    Button("Grant Accessibility") {
                        permissionsManager.requestAccessibilityAccess()
                        refreshShellState()
                    }
                }
                .buttonStyle(.bordered)

                HStack {
                    Button(hotkeyMonitor.isMonitoring ? "Stop Monitoring" : "Start Monitoring") {
                        if hotkeyMonitor.isMonitoring {
                            hotkeyMonitor.stopMonitoring()
                        } else {
                            hotkeyMonitor.startMonitoring()
                        }
                        refreshShellState()
                    }

                    Spacer()

                    Text(shellState.statusSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Capture") {
                Label(shellState.captureStatusText, systemImage: "record.circle")
                Text(shellState.captureDetailText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let latestArtifact = shellState.recentCapturedUtterances.first {
                    Text("Latest artifact: \(latestArtifact.fileURL.path)")
                        .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }

            Section("Transcription") {
                Label(shellState.transcriptionStatusText, systemImage: "text.bubble")
                Text(shellState.transcriptionDetailText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let latestTranscription = shellState.recentTranscribedUtterances.first {
                    Text("Latest transcript: \(latestTranscription.transcriptURL.path)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Upcoming phases") {
                Text("Phase 12.7 will insert dictated text into the focused terminal or text field without pressing Enter.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Section("Voice Commands") {
                Text("Say these phrases while dictating to insert special characters or formatting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(VoiceCommand.allCases) { command in
                    HStack {
                        Text("\"\(command.spokenPhrase)\"")
                            .font(.body.monospaced())
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(command.insertionText)
                            .font(.body.monospaced().weight(.semibold))
                            .foregroundStyle(.indigo)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 360)
    }

    private func refreshShellState() {
        permissionsManager.refreshStates()
        shellState.refreshIntegrationState(
            microphoneState: permissionsManager.microphoneState,
            accessibilityState: permissionsManager.accessibilityState,
            allRequiredGranted: permissionsManager.allRequiredGranted,
            isMonitoringHotkey: hotkeyMonitor.isMonitoring,
            isPushToTalkPressed: hotkeyMonitor.isPushToTalkPressed,
            hotkeyDisplayName: hotkeyMonitor.hotkeyDisplayName
        )
    }
}
