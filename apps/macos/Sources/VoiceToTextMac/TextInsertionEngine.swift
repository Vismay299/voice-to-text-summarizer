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

// MARK: - KnownAppType

/// Classifies the frontmost app to determine the best insertion strategy.
/// Series 11: expanded beyond terminals to cover browsers, plain text editors,
/// and rich editors with app-specific fallback handling.
public enum KnownAppType: String, Codable, Sendable, Hashable {
    /// Terminal emulators — use bracketed/plain paste, strip newlines for safety.
    case terminal
    /// Web browsers — paste into textareas, handle Shadow DOM limitations.
    case browser
    /// Plain text editors (TextEdit, Notes, Xcode) — AX works well.
    case plainTextEditor
    /// Rich editors (Notion, VS Code, JetBrains) — AX may be unreliable,
    /// paste is the safest fallback.
    case richEditor
    /// Unknown app — try AX, fall back to paste.
    case unknown

    /// Classification by bundle ID. This is the primary signal for choosing
    /// the insertion strategy before AX detection runs.
    static func classify(bundleId: String) -> KnownAppType {
        switch bundleId {
        // Terminals (Series 9 + 11)
        case "com.apple.Terminal",
             "com.googlecode.iterm2",
             "com.googlecode.iterm2-beta",
             "dev.warp.Warp-Stable",
             "net.kovidgoyal.kitty",
             "org.alacritty",
             "com.mitchellh.ghostty":
            return .terminal

        // Browsers (Series 11)
        case "com.google.Chrome",
             "com.google.Chrome.beta",
             "com.google.Chrome.dev",
             "com.google.Chrome.canary",
             "org.mozilla.firefox",
             "org.mozilla.firefoxdeveloperedition",
             "com.apple.Safari",
             "com.apple.SafariTechnologyPreview",
             "com.microsoft.edgemac",
             "com.brave.Browser":
            return .browser

        // Rich editors (Series 11) — AX is unreliable, prefer paste
        case "com.notion.id",
             "com.microsoft.VSCode",
             "com.microsoft.VSCodeInsiders",
             "com.jetbrains.intellij",
             "com.jetbrains.pycharm":
            return .richEditor

        // Plain text editors — AX works well
        case "com.apple.TextEdit",
             "com.apple.Notes",
             "com.apple.dt.Xcode",
             "com.sublimetext.4",
             "com.sublimetext.3",
             "com.macromates.TextMate.preview",
             "com.barebones.bbedit",
             "com.panic.Nova",
             "com.coteditor.CotEditor":
            return .plainTextEditor

        default:
            return .unknown
        }
    }

    /// Whether this app type should skip AX and use clipboard paste directly.
    /// Terminals always use paste (for bracketed paste safety).
    /// Rich editors prefer paste (AX is unreliable).
    /// Browsers use paste (AX can't reach Shadow DOM textareas reliably).
    var prefersPaste: Bool {
        switch self {
        case .terminal, .browser, .richEditor:
            return true
        case .plainTextEditor, .unknown:
            return false
        }
    }

}

// MARK: - TerminalAppMode

/// How a known terminal app handles paste operations.
/// Terminal Hardening (Phase 12.9): terminals that support bracketed paste
/// can safely receive multiline text without auto-execution.
enum TerminalAppMode {
    /// Supports bracketed paste (\x1b[200~ ... \x1b[201~).
    case bracketedPaste
    /// Falls back to plain paste (Cmd+V). Newlines are stripped for safety.
    case plainPaste

    /// Known terminal bundle IDs and their paste mode.
    static func mode(for bundleId: String) -> TerminalAppMode? {
        switch bundleId {
        case "com.googlecode.iterm2",
             "com.googlecode.iterm2-beta",
             "dev.warp.Warp-Stable",
             "net.kovidgoyal.kitty",
             "com.mitchellh.ghostty":
            return .bracketedPaste
        case "com.apple.Terminal",
             "org.alacritty":
            return .plainPaste
        default:
            return nil
        }
    }
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
/// Series 11 — Editor Compatibility:
/// - Classifies apps via KnownAppType (terminal/browser/richEditor/plainTextEditor)
/// - Terminals: bracketed/plain paste with newline safety (Phase 12.9)
/// - Browsers + rich editors: clipboard paste (AX unreliable for Shadow DOM / Electron)
/// - Plain text editors: AX cursor placement with paste fallback
/// - Insertion failure is surfaced to the user, never silent
@MainActor
public final class TextInsertionEngine: ObservableObject, Sendable {
    @Published public private(set) var state: InsertionState = .idle

    private enum PasteEventTap {
        case hid
        case session
    }

    /// Callback invoked when insertion fails after all retries.
    /// Set by the coordinator to surface errors to the user.
    public var onInsertionFailure: ((String) -> Void)?

    private static let log = Logger(subsystem: "com.voicetotext.shell", category: "insertion")

    /// ANSI escape sequence markers for bracketed paste.
    private static let bracketedPasteStart = "\u{001B}[200~"
    private static let bracketedPasteEnd = "\u{001B}[201~"

    /// Series 13: reduced from 50ms → 10ms.
    private static let focusDelayNanoseconds: UInt64 = 10_000_000
    private static let appActivationDelayNanoseconds: UInt64 = 200_000_000
    /// Series 13: reduced from 500ms → 200ms.
    private static let pasteRestoreDelayNanoseconds: UInt64 = 200_000_000
    /// Use the session tap only for the first paste right after wake.
    /// Normal insertions should keep using the previously working HID path.
    private static let postWakeSessionTapWindow: TimeInterval = 15

    nonisolated(unsafe) private var workspaceDidWakeObserver: NSObjectProtocol?
    private var lastWakeDate: Date?

    public init() {
        workspaceDidWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastWakeDate = Date()
            }
        }
    }

    deinit {
        if let workspaceDidWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceDidWakeObserver)
        }
    }

    // MARK: - Public API

    /// Insert text into the currently focused editable element.
    /// Returns an `InsertionResult` describing the outcome.
    ///
    /// SAFETY: This method NEVER simulates pressing Enter/Return.
    /// The inserted text appears at the cursor and the user must manually submit.
    public func insertText(_ text: String) async -> InsertionResult {
        await insertText(text, asFragment: false, requireTerminalTarget: false)
    }

    private func insertText(_ text: String, asFragment: Bool, requireTerminalTarget: Bool) async -> InsertionResult {
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
            onInsertionFailure?(result.errorMessage!)
            return result
        }

        state = .detectingTarget

        guard let target = currentInsertionTarget() else {
            let result = InsertionResult(
                success: false,
                strategy: .notAvailable,
                targetAppBundleId: nil,
                targetAppName: nil,
                errorMessage: "No frontmost application found.",
                insertedTextPreview: textPreview(text)
            )
            state = .failed(result.errorMessage!)
            onInsertionFailure?(result.errorMessage!)
            return result
        }

        if requireTerminalTarget && target.appType != .terminal {
            let result = InsertionResult(
                success: false,
                strategy: .notAvailable,
                targetAppBundleId: target.bundleId,
                targetAppName: target.appName,
                errorMessage: "Live insertion is only supported for terminal targets.",
                insertedTextPreview: textPreview(text)
            )
            state = .failed(result.errorMessage!)
            return result
        }

        // Known app types that prefer paste over AX:
        // - Terminals: bracketed/plain paste for safety (Series 9)
        // - Browsers: AX can't reach Shadow DOM textareas (Series 11)
        // - Rich editors: AX is unreliable (Series 11)
        if target.appType.prefersPaste || asFragment {
            return await insertViaPaste(
                text,
                appBundleId: target.bundleId,
                appName: target.appName,
                appType: target.appType,
                asFragment: asFragment
            )
        }

        // Try AX text field first for plain text editors and unknown apps.
        let axResult = await insertViaAccessibility(text, app: target.app, bundleId: target.bundleId, appName: target.appName)
        if axResult.success {
            return axResult
        }

        // Fall back to clipboard paste.
        let pasteResult = await insertViaPaste(
            text,
            appBundleId: target.bundleId,
            appName: target.appName,
            appType: target.appType,
            asFragment: asFragment
        )

        // Surface failure if both AX and paste fail.
        if !pasteResult.success {
            onInsertionFailure?(pasteResult.errorMessage ?? "Unknown insertion error")
        }

        return pasteResult
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

    // MARK: - Clipboard Paste (Fallback for terminals, browsers, and rich editors)

    private func insertViaPaste(
        _ text: String,
        appBundleId: String,
        appName: String,
        appType: KnownAppType,
        asFragment: Bool
    ) async -> InsertionResult {
        state = .inserting(strategy: .pasteViaClipboard)

        try? await Task.sleep(nanoseconds: Self.focusDelayNanoseconds)

        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)

        // Sanitize text based on app type.
        let sanitized = sanitizeForInsertion(text, appType: appType, bundleId: appBundleId, asFragment: asFragment)
        // Build the final pasteboard content ONCE, before activation.
        let finalContent: String
        if appType == .terminal && terminalMode(bundleId: appBundleId) == .bracketedPaste {
            finalContent = Self.bracketedPasteStart + sanitized + Self.bracketedPasteEnd
        } else {
            finalContent = sanitized
        }

        pasteboard.clearContents()
        pasteboard.setString(finalContent, forType: .string)

        let markerType = NSPasteboard.PasteboardType("com.voicetotext.insertion-marker")
        pasteboard.setString(UUID().uuidString, forType: markerType)

        // Activate the target app FIRST, then send Cmd+V.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleId).first else {
            let result = InsertionResult(
                success: false,
                strategy: .pasteViaClipboard,
                targetAppBundleId: appBundleId,
                targetAppName: appName,
                errorMessage: "Could not activate target application.",
                insertedTextPreview: textPreview(text)
            )
            state = .failed(result.errorMessage!)
            onInsertionFailure?(result.errorMessage!)
            return result
        }

        // Series 13: skip activation delay if the target app is already frontmost.
        if app.isActive {
            Self.log.debug("Target app already frontmost — skipping activation delay")
        } else {
            app.activate(options: .activateIgnoringOtherApps)
            try? await Task.sleep(nanoseconds: Self.appActivationDelayNanoseconds)
        }

        // Simulate Cmd+V after the target app is frontmost so it receives the paste.
        simulateCmdV(using: currentPasteEventTap())

        // Safe clipboard restore: only restore if the marker is still present.
        let markerBeforeRestore = pasteboard.string(forType: markerType)
        let oldContentsForRestore = oldContents

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.pasteRestoreDelayNanoseconds)
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

    // MARK: - Text Sanitization

    /// Sanitize dictated text before pasting into the target app.
    /// Series 11: handles terminals, browsers, and rich editors with
    /// app-appropriate rules.
    private func sanitizeForInsertion(_ text: String, appType: KnownAppType, bundleId: String, asFragment: Bool) -> String {
        switch appType {
        case .terminal:
            return sanitizeForTerminal(text, bundleId: bundleId, asFragment: asFragment)
        case .browser, .richEditor, .plainTextEditor, .unknown:
            // No sanitization needed — these app types handle pasted text safely.
            return asFragment ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Return the terminal paste mode for a given bundle ID.
    private func terminalMode(bundleId: String) -> TerminalAppMode? {
        TerminalAppMode.mode(for: bundleId)
    }

    /// Sanitize text for terminal targets.
    /// Phase 12.9 — multiline-aware sanitization:
    ///
    /// - **Bracketed paste mode** (iTerm2, Warp, Kitty): newlines are preserved.
    /// - **Plain paste mode** (Terminal.app, Alacritty): newlines replaced with spaces.
    @_spi(Testing) public func sanitizeForTerminal(_ text: String, bundleId: String, asFragment: Bool = false) -> String {
        let mode = TerminalAppMode.mode(for: bundleId)
        guard mode != nil else { return text }
        return sanitizeForTerminal(text, mode: mode, asFragment: asFragment)
    }

    private func sanitizeForTerminal(_ text: String, mode: TerminalAppMode?, asFragment: Bool) -> String {
        var result = text

        // Always strip ANSI escape sequences (CSI + OSC).
        if let ansiRegex = try? NSRegularExpression(
            pattern: "\\x1B\\[[0-9;]*[a-zA-Z]|\\x1B\\].*?(?:\\x07|\\x1B\\\\)",
            options: [.dotMatchesLineSeparators]
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = ansiRegex.stringByReplacingMatches(
                in: result, range: range, withTemplate: ""
            )
        }

        switch mode {
        case .bracketedPaste:
            return asFragment ? result : result.trimmingCharacters(in: .whitespacesAndNewlines)
        case .plainPaste, .none:
            result = result.replacingOccurrences(of: "\r\n", with: " ")
            result = result.replacingOccurrences(of: "\n", with: " ")
            result = result.replacingOccurrences(of: "\r", with: " ")
            if let spaceRegex = try? NSRegularExpression(pattern: " {2,}", options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = spaceRegex.stringByReplacingMatches(
                    in: result, range: range, withTemplate: " "
                )
            }
            return asFragment ? result : result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func currentPasteEventTap() -> PasteEventTap {
        guard let lastWakeDate else {
            return .hid
        }

        let isWithinWakeRecoveryWindow = Date().timeIntervalSince(lastWakeDate) <= Self.postWakeSessionTapWindow
        guard isWithinWakeRecoveryWindow else {
            self.lastWakeDate = nil
            return .hid
        }

        // Consume the recovery path once, then return to HID for normal operation.
        self.lastWakeDate = nil
        return .session
    }

    /// Simulate a Cmd+V keystroke.
    /// SAFETY: This method only sends the V key with the Command modifier.
    /// It does NOT send Enter, Return, or any other key.
    ///
    private func simulateCmdV(using tap: PasteEventTap) {
        let source = CGEventSource(stateID: .hidSystemState)

        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vKeyDown?.flags = .maskCommand
        vKeyDown?.post(tap: tap == .session ? .cgSessionEventTap : .cghidEventTap)

        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vKeyUp?.flags = .maskCommand
        vKeyUp?.post(tap: tap == .session ? .cgSessionEventTap : .cghidEventTap)
    }

    // MARK: - Helpers

    private func textPreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return trimmed }
        return "\(trimmed.prefix(80))…"
    }

    private func currentInsertionTarget() -> (app: NSRunningApplication, bundleId: String, appName: String, appType: KnownAppType)? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleId = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? bundleId
        let appType = KnownAppType.classify(bundleId: bundleId)
        return (app, bundleId, appName, appType)
    }
}
