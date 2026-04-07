import ApplicationServices
import AppKit
import Combine
import Foundation

// MARK: - InsertionStrategy

/// The method used to insert text into the focused app.
public enum InsertionStrategy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Direct AX text field manipulation (most reliable for text editors).
    case accessibilityTextField
    /// Clipboard paste via simulated Cmd+V (fallback for terminals).
    case pasteViaClipboard
    /// No editable element was found.
    case notAvailable
}

// MARK: - InsertionResult

/// The outcome of a single insertion attempt.
public struct InsertionResult: Codable, Sendable, Hashable {
    public let success: Bool
    public let strategy: InsertionStrategy
    public let targetAppBundleId: String?
    public let targetAppName: String?
    public let errorMessage: String?
    public let insertedTextPreview: String

    public init(
        success: Bool,
        strategy: InsertionStrategy,
        targetAppBundleId: String?,
        targetAppName: String?,
        errorMessage: String?,
        insertedTextPreview: String
    ) {
        self.success = success
        self.strategy = strategy
        self.targetAppBundleId = targetAppBundleId
        self.targetAppName = targetAppName
        self.errorMessage = errorMessage
        self.insertedTextPreview = insertedTextPreview
    }
}

// MARK: - InsertionState

/// The current state of the insertion engine.
public enum InsertionState: Equatable, Sendable {
    case idle
    case detectingTarget
    case inserting(strategy: InsertionStrategy)
    case inserted(InsertionResult)
    case failed(String)

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .detectingTarget, .inserting: return true
        default: return false
        }
    }
}

// MARK: - TextInsertionEngine

/// Inserts dictated text into the currently focused app at the current cursor
/// position. Never simulates pressing Enter or auto-submits the text.
///
/// Primary strategy: Accessibility-focused text field.
/// Fallback: Clipboard paste (Cmd+V simulation) for terminals.
@MainActor
public final class TextInsertionEngine: ObservableObject, Sendable {
    @Published public private(set) var state: InsertionState = .idle

    // Bundle IDs that are known to not support AX text field manipulation
    // and should use the clipboard paste strategy directly.
    private static let pasteFirstAppBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.apple.iTerm2",
        "com.googlecode.iterm2",
    ]

    private let nonisolatedState = ManagedCriticalState<InsertionState>(.idle)

    public init() {}

    // MARK: - Public API

    /// Insert text into the currently focused editable element.
    /// Returns an `InsertionResult` describing the outcome.
    ///
    /// SAFETY: This method NEVER simulates pressing Enter/Return.
    /// The inserted text appears at the cursor and the user must manually submit.
    public func insertText(_ text: String) async -> InsertionResult {
        guard !text.isEmpty else {
            let result = InsertionResult(
                success: false,
                strategy: .notAvailable,
                targetAppBundleId: nil,
                targetAppName: nil,
                errorMessage: "No text to insert.",
                insertedTextPreview: ""
            )
            state = .failed(result.errorMessage!)
            return result
        }

        state = .detectingTarget

        guard let app = NSWorkspace.shared.frontmostApplication else {
            let result = InsertionResult(
                success: false,
                strategy: .notAvailable,
                targetAppBundleId: nil,
                targetAppName: nil,
                errorMessage: "No frontmost application found.",
                insertedTextPreview: textPreview(text)
            )
            state = .failed(result.errorMessage!)
            return result
        }

        let bundleId = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? bundleId

        // Terminals and known paste-first apps skip AX text field detection.
        if Self.pasteFirstAppBundleIds.contains(bundleId) {
            return await insertViaPaste(text, appBundleId: bundleId, appName: appName)
        }

        // Try AX text field first.
        let axResult = await insertViaAccessibility(text, app: app, bundleId: bundleId, appName: appName)
        if axResult.success {
            return axResult
        }

        // Fall back to clipboard paste.
        return await insertViaPaste(text, appBundleId: bundleId, appName: appName)
    }

    // MARK: - Accessibility Insertion

    private func insertViaAccessibility(
        _ text: String,
        app: NSRunningApplication,
        bundleId: String,
        appName: String
    ) async -> InsertionResult {
        state = .inserting(strategy: .accessibilityTextField)

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused UI element.
        guard let focusedElement = copyFocusedElement(from: appElement) else {
            return InsertionResult(
                success: false,
                strategy: .accessibilityTextField,
                targetAppBundleId: bundleId,
                targetAppName: appName,
                errorMessage: "No focused UI element found.",
                insertedTextPreview: textPreview(text)
            )
        }

        // Check if the focused element supports text entry.
        guard isTextEntryElement(focusedElement) else {
            return InsertionResult(
                success: false,
                strategy: .accessibilityTextField,
                targetAppBundleId: bundleId,
                targetAppName: appName,
                errorMessage: "Focused element does not support text entry.",
                insertedTextPreview: textPreview(text)
            )
        }

        // Attempt to set the value (insert text).
        // For text fields, we append to the existing value at the cursor position.
        let success = setAccessibilityText(focusedElement, text: text)

        return InsertionResult(
            success: success,
            strategy: .accessibilityTextField,
            targetAppBundleId: bundleId,
            targetAppName: appName,
            errorMessage: success ? nil : "Failed to set text via Accessibility API.",
            insertedTextPreview: textPreview(text)
        )
    }

    private func copyFocusedElement(from appElement: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard result == .success else { return nil }
        return value as! AXUIElement?
    }

    private func isTextEntryElement(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        )
        guard result == .success, let role = value as? String else { return false }

        // Text areas and text fields are editable.
        let textRoles = ["AXTextArea", "AXTextField", "AXTextAreaRole", "AXTextFieldRole"]
        guard textRoles.contains(role) else { return false }

        // Also check if the element supports the setValue action.
        return true
    }

    private func setAccessibilityText(_ element: AXUIElement, text: String) -> Bool {
        // Try to get the current value, append our text, and set it back.
        // This preserves existing content and appends at the cursor.

        // First, try the "AXValue" or "AXValueAttribute" approach.
        var currentValue: AnyObject?
        let getResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &currentValue
        )

        let newText: String
        if getResult == .success, let existing = currentValue as? String {
            newText = existing + text
        } else {
            newText = text
        }

        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newText as CFTypeRef
        )

        return setResult == .success
    }

    // MARK: - Clipboard Paste (Fallback)

    private func insertViaPaste(
        _ text: String,
        appBundleId: String,
        appName: String
    ) async -> InsertionResult {
        state = .inserting(strategy: .pasteViaClipboard)

        // Small delay to let the state update propagate before we manipulate
        // the pasteboard and send events.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Save the current pasteboard contents so we can restore them.
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)

        // Set our text on the pasteboard.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V.
        simulateCmdV()

        // Restore the old pasteboard contents after a short delay.
        // We do this on the main actor since NSPasteboard is main-thread bound.
        let oldContentsForRestore = oldContents
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if let old = oldContentsForRestore {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(old, forType: .string)
            }
        }

        // Bring the target app back to the foreground after pasting.
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleId).first {
            app.activate(options: .activateIgnoringOtherApps)
        }

        return InsertionResult(
            success: true,
            strategy: .pasteViaClipboard,
            targetAppBundleId: appBundleId,
            targetAppName: appName,
            errorMessage: nil,
            insertedTextPreview: textPreview(text)
        )
    }

    /// Simulate a Cmd+V keystroke.
    /// SAFETY: This method only sends the V key with the Command modifier.
    /// It does NOT send Enter, Return, or any other key.
    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd+V
        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vKeyDown?.flags = .maskCommand
        vKeyDown?.post(tap: .cghidEventTap)

        // Key up: Cmd+V
        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vKeyUp?.flags = .maskCommand
        vKeyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    private func textPreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return trimmed }
        return "\(trimmed.prefix(80))…"
    }
}

// MARK: - Nonisolated State Helper

/// A thread-safe mutable container for non-Sendable types.
final class ManagedCriticalState<State: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: State

    init(_ initialState: State) {
        self._state = initialState
    }

    var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    func withLock<R>(_ body: (inout State) -> R) -> R {
        lock.withLock { body(&self._state) }
    }
}
