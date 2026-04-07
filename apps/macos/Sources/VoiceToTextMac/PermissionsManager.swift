import ApplicationServices
import AVFoundation
import Combine
import Foundation

public enum PermissionState: Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
    case unavailable

    public var isGranted: Bool {
        if case .granted = self {
            return true
        }
        return false
    }

    public var title: String {
        switch self {
        case .notDetermined:
            return "Not Ready"
        case .granted:
            return "Granted"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .unavailable:
            return "Unavailable"
        }
    }

    public var subtitle: String {
        switch self {
        case .notDetermined:
            return "Permission is still pending."
        case .granted:
            return "Permission is ready."
        case .denied:
            return "Permission was denied."
        case .restricted:
            return "Permission is restricted by system policy."
        case .unavailable:
            return "Permission is not available on this machine."
        }
    }

    public var symbolName: String {
        switch self {
        case .notDetermined:
            return "questionmark.circle.fill"
        case .granted:
            return "checkmark.seal.fill"
        case .denied:
            return "xmark.octagon.fill"
        case .restricted:
            return "lock.circle.fill"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    public static func microphone(from status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .granted
        @unknown default:
            return .unavailable
        }
    }

    public static func accessibility(trusted: Bool) -> PermissionState {
        trusted ? .granted : .notDetermined
    }
}

@MainActor
public final class PermissionsManager: ObservableObject {
    @Published public private(set) var microphoneState: PermissionState = .notDetermined
    @Published public private(set) var accessibilityState: PermissionState = .notDetermined

    public var allRequiredGranted: Bool {
        microphoneState.isGranted && accessibilityState.isGranted
    }

    public init(refreshImmediately: Bool = true) {
        if refreshImmediately {
            refreshStates()
        }
    }

    public func refreshStates() {
        microphoneState = PermissionState.microphone(
            from: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        accessibilityState = PermissionState.accessibility(
            trusted: AXIsProcessTrusted()
        )
    }

    public func requestAccessibilityAccess() {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshStates()
    }

    public func requestMicrophoneAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refreshStates()

        if !granted, microphoneState == .notDetermined {
            microphoneState = .denied
        }
    }

    public func setStatesForTesting(microphone: PermissionState, accessibility: PermissionState) {
        microphoneState = microphone
        accessibilityState = accessibility
    }
}
