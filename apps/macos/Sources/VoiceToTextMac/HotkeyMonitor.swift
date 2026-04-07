import AppKit
import Foundation
import SwiftUI

public enum HotkeyTransition: Equatable {
    case pressed
    case released
    case ignored
}

public struct HotkeyEventSnapshot: Equatable {
    public let keyCode: UInt16
    public let isRightOptionPressed: Bool

    public init(keyCode: UInt16, isRightOptionPressed: Bool) {
        self.keyCode = keyCode
        self.isRightOptionPressed = isRightOptionPressed
    }
}

public enum HotkeyEventInterpreter {
    public static let rightOptionKeyCode: UInt16 = 61

    public static func transition(for snapshot: HotkeyEventSnapshot) -> HotkeyTransition {
        guard snapshot.keyCode == rightOptionKeyCode else {
            return .ignored
        }

        return snapshot.isRightOptionPressed ? .pressed : .released
    }
}

@MainActor
public final class HotkeyMonitor: ObservableObject {
    @Published public var isMonitoring = false
    @Published public var isPushToTalkPressed = false

    public let hotkeyDisplayName = "Hold Right Option"

    private var globalMonitorToken: Any?
    private var localMonitorToken: Any?

    public init() {}

    public func startMonitoring() {
        guard !isMonitoring else {
            return
        }

        isMonitoring = true
        installMonitors()
    }

    public func stopMonitoring() {
        removeMonitors()
        isMonitoring = false
        isPushToTalkPressed = false
    }

    private func installMonitors() {
        let globalToken = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.apply(event: event)
            }
        }

        let localToken = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.apply(event: event)
            }
            return event
        }

        globalMonitorToken = globalToken
        localMonitorToken = localToken
    }

    private func removeMonitors() {
        if let globalMonitorToken {
            NSEvent.removeMonitor(globalMonitorToken)
            self.globalMonitorToken = nil
        }

        if let localMonitorToken {
            NSEvent.removeMonitor(localMonitorToken)
            self.localMonitorToken = nil
        }
    }

    private func apply(event: NSEvent) {
        let snapshot = HotkeyEventSnapshot(
            keyCode: event.keyCode,
            isRightOptionPressed: event.keyCode == HotkeyEventInterpreter.rightOptionKeyCode &&
                event.modifierFlags.contains(.option)
        )

        switch HotkeyEventInterpreter.transition(for: snapshot) {
        case .pressed:
            isPushToTalkPressed = true
        case .released:
            isPushToTalkPressed = false
        case .ignored:
            break
        }
    }
}
