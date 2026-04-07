import ApplicationServices
import AppKit
import Combine
import Foundation
import os.log

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
/// Primary strategy: Accessibility-focused text field at the cursor position.
/// Fallback: Clipboard paste (Cmd+V simulation) for terminals.
@MainActor
public final class TextInsertionEngine: ObservableObject, Sendable {
    @Published public private(set) var state: InsertionState = .idle

    /// Bundle IDs that should skip AX and use clipboard paste directly.
    private static let pasteFirstAppBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    private static let log = Logger(subsystem: "com.voicetotext.shell", category: "insertion")

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

        guard let focusedElement = copyFocusedElement(from: appElement) else {
            Self.log.debug("AX: no focused element found")
            return InsertionResult(
                success: false,
                strategy: .accessibilityTextField,
                targetAppBundleId: bundleId,
                targetAppName: appName,
                errorMessage: "No focused UI element found.",
                insertedTextPreview: textPreview(text)
            )
        }

        guard isTextEntryElement(focusedElement) else {
            Self.log.debug("AX: element is not a text entry element")
            return InsertionResult(
                success: false,
                strategy: .accessibilityTextField,
                targetAppBundleId: bundleId,
                targetAppName: appName,
                errorMessage: "Focused element does not support text entry.",
                insertedTextPreview: textPreview(text)
            )
        }

        let success = insertTextAtCursor(focusedElement, text: text)
        if !success {
            Self.log.debug("AX: failed to insert text at cursor")
        }

        return InsertionResult(
            success: success,
            strategy: .accessibilityTextField,
            targetAppBundleId: bundleId,
            targetAppName: appName,
            errorMessage: success ? nil : "Failed to insert text at cursor via Accessibility API.",
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
        return (value as! AXUIElement)
    }

    /// Check if the element supports text entry by verifying:
    /// 1. Role is AXTextArea or AXTextField
    /// 2. AXEditable attribute is true (if available)
    private func isTextEntryElement(_ element: AXUIElement) -> Bool {
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else { return false }

        let textRoles = ["AXTextArea", "AXTextField"]
        guard textRoles.contains(role) else { return false }

        // Check AXEditable attribute (string literal since no constant exists).
        var editableValue: AnyObject?
        let editableResult = AXUIElementCopyAttributeValue(
            element,
            "AXEditable" as CFString,
            &editableValue
        )
        if editableResult == .success, let editable = editableValue as? Bool {
            return editable
        }

        // If AXEditable is not available, assume text roles are editable.
        return true
    }

    /// Insert text at the current cursor position using AXSelectedTextRange.
    /// This respects the cursor location instead of blindly appending to the end.
    private func insertTextAtCursor(_ element: AXUIElement, text: String) -> Bool {
        var rangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        if rangeResult == .success, let range = rangeValue as! AXValue? {
            var currentValue: AnyObject?
            let getResult = AXUIElementCopyAttributeValue(
                element,
                kAXValueAttribute as CFString,
                &currentValue
            )

            if getResult == .success, let existing = currentValue as? String {
                var cfRange = CFRange()
                if AXValueGetValue(range, .cfRange, &cfRange) {
                    let location = cfRange.location
                    let length = cfRange.length

                    // Build UTF-16 indices for the splice.
                    let startUTF16 = existing.utf16.index(existing.utf16.startIndex, offsetBy: location)
                    let endUTF16 = existing.utf16.index(startUTF16, offsetBy: length)

                    guard let start = String.Index(startUTF16, within: existing),
                          let end = String.Index(endUTF16, within: existing) else {
                        return setAccessibilityText(element, text: text)
                    }

                    let before = existing[..<start]
                    let after = existing[end...]
                    let newText = before + text + after

                    let setResult = AXUIElementSetAttributeValue(
                        element,
                        kAXValueAttribute as CFString,
                        String(newText) as CFTypeRef
                    )

                    if setResult == .success {
                        let newLocation = location + text.utf16.count
                        updateCursorPosition(element, to: newLocation)
                        return true
                    }
                }
            }
        }

        // Fallback: simple append if we can't get the selection range.
        Self.log.debug("AX: falling back to simple append (no selection range)")
        return setAccessibilityText(element, text: text)
    }

    private func updateCursorPosition(_ element: AXUIElement, to location: Int) {
        var newRange = CFRange(location: location, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &newRange) else { return }
        _ = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
    }

    /// Fallback: set the entire text value (append mode).
    private func setAccessibilityText(_ element: AXUIElement, text: String) -> Bool {
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

        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)

        // Sanitize text for terminal targets — strip newlines and ANSI escapes.
        let sanitized = sanitizeForTerminal(text, bundleId: appBundleId)

        // Set our text on the pasteboard.
        pasteboard.clearContents()
        pasteboard.setString(sanitized, forType: .string)

        // Mark the pasteboard so we can detect if the user copies something else.
        let markerType = NSPasteboard.PasteboardType("com.voicetotext.insertion-marker")
        pasteboard.setString(UUID().uuidString, forType: markerType)

        // Fix: Activate the target app FIRST, then send Cmd+V.
        // Otherwise the keystroke goes to the menu bar app instead.
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleId).first {
            app.activate(options: .activateIgnoringOtherApps)
        }

        // Wait for the target app to actually gain focus.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Simulate Cmd+V — now the target app is frontmost so it receives the paste.
        simulateCmdV()

        // Safe clipboard restore: only restore if the marker is still present.
        let markerBeforeRestore = pasteboard.string(forType: markerType)
        let oldContentsForRestore = oldContents

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            let pb = NSPasteboard.general
            if pb.string(forType: markerType) == markerBeforeRestore {
                if let old = oldContentsForRestore {
                    pb.clearContents()
                    pb.setString(old, forType: .string)
                }
            } else {
                Self.log.debug("Pasteboard: user copied something new, skipping restore")
            }
            pb.setString("", forType: markerType)
        }

        return InsertionResult(
            success: true,
            strategy: .pasteViaClipboard,
            targetAppBundleId: appBundleId,
            targetAppName: appName,
            errorMessage: nil,
            insertedTextPreview: textPreview(sanitized)
        )
    }

    /// Sanitize text for terminal targets.
    /// Strips newlines (\n, \r) and ANSI escape sequences to prevent
    /// accidental command execution when pasting into a terminal.
    private func sanitizeForTerminal(_ text: String, bundleId: String) -> String {
        guard Self.pasteFirstAppBundleIds.contains(bundleId) else { return text }

        var result = text

        // Strip ANSI escape sequences.
        if let ansiRegex = try? NSRegularExpression(
            pattern: "\\x1B\\[[0-9;]*[a-zA-Z]",
            options: []
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = ansiRegex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: ""
            )
        }

        // Replace newlines and carriage returns with spaces.
        result = result.replacingOccurrences(of: "\r\n", with: " ")
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: "\r", with: " ")

        // Collapse multiple spaces.
        if let spaceRegex = try? NSRegularExpression(pattern: " {2,}", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = spaceRegex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: " "
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Simulate a Cmd+V keystroke.
    /// SAFETY: This method only sends the V key with the Command modifier.
    /// It does NOT send Enter, Return, or any other key.
    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)

        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vKeyDown?.flags = .maskCommand
        vKeyDown?.post(tap: .cghidEventTap)

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
