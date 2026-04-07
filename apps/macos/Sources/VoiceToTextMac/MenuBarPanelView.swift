import AppKit
import SwiftUI

public struct MenuBarPanelView: View {
    @EnvironmentObject private var shellState: ShellState
    @EnvironmentObject private var permissionsManager: PermissionsManager
    @EnvironmentObject private var hotkeyMonitor: HotkeyMonitor
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: shellState.shellStatus.symbolName)
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(shellState.shellStatus == .ready ? .green : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice Dictation")
                        .font(.headline)
                    Text(shellState.readinessLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(shellState.statusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Dictation Mode")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Active mode indicator pill
                    HStack(spacing: 4) {
                        Circle()
                            .fill(shellState.selectedMode.badgeColor)
                            .frame(width: 6, height: 6)
                        Text(shellState.selectedMode.rawValue)
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(shellState.selectedMode.badgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(shellState.selectedMode.badgeColor.opacity(0.12))
                    .clipShape(Capsule())
                }

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

                Text(shellState.selectedMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Setup")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                shellStepRow(shellState.microphoneStatusText, icon: "mic")
                shellStepRow(shellState.accessibilityStatusText, icon: "accessibility")
                shellStepRow(shellState.hotkeyStatusText, icon: "command")
                shellStepRow(shellState.captureStatusText, icon: "record.circle")
                shellStepRow(shellState.transcriptionStatusText, icon: "text.bubble")
                shellStepRow(shellState.insertionStatusText, icon: "arrowshape.turn.up.left")
            }

            Text(shellState.captureDetailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(shellState.transcriptionDetailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Insertion section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("Auto-insert", isOn: $shellState.autoInsertEnabled)
                        .font(.caption)
                    Spacer()
                    if shellState.autoInsertEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(shellState.insertionStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(insertionStatusColor)
                Text(shellState.insertionDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastResult = shellState.recentInsertionResult {
                    HStack(spacing: 4) {
                        Image(systemName: lastResult.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(lastResult.success ? .green : .red)
                        Text(lastResult.insertedTextPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(lastResult.strategy.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Refresh") {
                    refreshShellState()
                }

                Button("Grant Mic") {
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
                Button(shellState.isHotkeyMonitoring ? "Stop Hotkey" : "Start Hotkey") {
                    if hotkeyMonitor.isMonitoring {
                        hotkeyMonitor.stopMonitoring()
                    } else {
                        hotkeyMonitor.startMonitoring()
                    }
                    refreshShellState()
                }

                Spacer()

                Text(shellState.hotkeyDisplayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Open History") {
                    openWindow(id: "history")
                }

                Spacer()

                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 360)
    }

    private var insertionStatusColor: Color {
        switch shellState.currentInsertionState {
        case .idle: return .secondary
        case .detectingTarget: return .blue
        case .inserting: return .orange
        case .inserted: return .green
        case .failed: return .red
        }
    }

    private func shellStepRow(_ title: String, icon: String) -> some View {
        let lowercased = title.lowercased()

        return HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
            Spacer()
            if lowercased.contains("recording") {
                Text("Recording")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else if lowercased.contains("transcribing") {
                Text("Active")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            } else if lowercased.contains("detecting") {
                Text("Detecting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            } else if lowercased.contains("inserting") && lowercased.contains("active") {
                Text("Inserting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if lowercased.contains("success") || lowercased.contains("saved") || lowercased.contains("granted") || lowercased.contains("monitoring") {
                Text("Ready")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else if lowercased.contains("pressed") || lowercased.contains("finalizing") {
                Text("Active")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else if lowercased.contains("failed") {
                Text("Failed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Text("Idle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
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
