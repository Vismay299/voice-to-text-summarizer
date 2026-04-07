import Foundation

// MARK: - VoiceCommand

/// A deterministic voice command that can be spoken to insert special characters
/// or formatting into dictation text.
public enum VoiceCommand: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case newLine
    case slashCommand
    case openQuote
    case codeBlock

    public var id: String { rawValue }

    /// The text inserted into the output when this command is recognized.
    public var insertionText: String {
        switch self {
        case .newLine:
            return "\n"
        case .slashCommand:
            return "/"
        case .openQuote:
            return "\""
        case .codeBlock:
            return "`"
        }
    }

    /// A human-readable display name for UI badges.
    public var displayName: String {
        switch self {
        case .newLine:
            return "New Line"
        case .slashCommand:
            return "Slash Cmd"
        case .openQuote:
            return "Open Quote"
        case .codeBlock:
            return "Code Block"
        }
    }

    /// The primary spoken phrase that triggers this command.
    public var spokenPhrase: String {
        switch self {
        case .newLine:
            return "new line"
        case .slashCommand:
            return "slash command"
        case .openQuote:
            return "open quote"
        case .codeBlock:
            return "code block"
        }
    }
}

// MARK: - VoiceCommandResult

/// The result of parsing voice commands from a text string.
public struct VoiceCommandResult: Codable, Sendable, Hashable {
    /// All commands detected in the text, in left-to-right order.
    public let commands: [VoiceCommand]
    /// The text with command phrases removed and replaced by their insertion text.
    public let cleanedText: String

    public init(commands: [VoiceCommand], cleanedText: String) {
        self.commands = commands
        self.cleanedText = cleanedText
    }
}

// MARK: - VoiceCommandParser

/// A deterministic, rule-based parser that detects voice commands in transcribed text
/// and replaces them with their corresponding insertion characters.
///
/// Commands are detected using exact phrase matching at word boundaries with
/// sentence-boundary heuristics to prevent false positives on natural speech.
public struct VoiceCommandParser: Sendable {

    /// Each command maps to its spoken trigger phrases (all lowercase for matching).
    /// Phrases are checked in order; the first match wins.
    private struct CommandPattern {
        let command: VoiceCommand
        let phrases: [String]
    }

    private let patterns: [CommandPattern]

    public init() {
        self.patterns = [
            CommandPattern(command: .newLine, phrases: ["new paragraph", "new line", "newline"]),
            CommandPattern(command: .slashCommand, phrases: ["slash command"]),
            CommandPattern(command: .openQuote, phrases: ["open quotes", "open quote"]),
            CommandPattern(command: .codeBlock, phrases: ["code block", "codeblock"]),
        ]
    }

    // MARK: - Public API

    /// Parse the given text for voice commands and return the result.
    ///
    /// Detection is deterministic and case-insensitive. Commands are only recognized
    /// when they appear at sentence boundaries to avoid false positives on natural
    /// speech (e.g., "a new line of code" will NOT trigger `.newLine`).
    ///
    /// Uses a single-pass strategy: collects all matches with positions from the
    /// original text, then applies replacements in reverse order so indices stay
    /// valid. No redundant re-scanning.
    ///
    /// - Parameter text: The text to parse (typically the output of TranscriptCleaner).
    /// - Returns: A `VoiceCommandResult` containing all detected commands and the cleaned text.
    public func parse(_ text: String) -> VoiceCommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VoiceCommandResult(commands: [], cleanedText: "")
        }

        // Single scan: collect all command matches with their positions.
        let locatedCommands = collectMatches(from: trimmed)

        if locatedCommands.isEmpty {
            return VoiceCommandResult(commands: [], cleanedText: trimmed)
        }

        // Apply replacements in reverse order so earlier indices remain valid.
        var result = trimmed
        for located in locatedCommands.reversed() {
            result = result.replacingCharacters(
                in: located.range,
                with: located.command.insertionText
            )
        }

        // Clean up leftover spacing artifacts.
        result = cleanupText(result)

        // Commands in left-to-right order.
        let commands = locatedCommands.map { $0.command }
        return VoiceCommandResult(commands: commands, cleanedText: result)
    }

    // MARK: - Single-Pass Detection

    /// A located command match: the command, its phrase, and its range in the original text.
    private struct LocatedCommand: Comparable {
        let command: VoiceCommand
        let phrase: String
        let range: Range<String.Index>

        static func < (lhs: LocatedCommand, rhs: LocatedCommand) -> Bool {
            lhs.range.lowerBound < rhs.range.lowerBound
        }
    }

    /// Collect all command matches from the text in a single pass.
    /// Returns matches sorted by position, with deduplication at overlapping locations.
    private func collectMatches(from text: String) -> [LocatedCommand] {
        var located: [LocatedCommand] = []

        for pattern in patterns {
            for phrase in pattern.phrases {
                guard let regex = buildBoundaryRegex(for: phrase) else {
                    continue
                }

                let range = NSRange(text.startIndex..., in: text)
                let matches = regex.matches(in: text, range: range)

                for match in matches {
                    guard let swiftRange = Range(match.range, in: text) else {
                        continue
                    }
                    located.append(LocatedCommand(
                        command: pattern.command,
                        phrase: phrase,
                        range: swiftRange
                    ))
                }
            }
        }

        // Sort by position.
        located.sort()

        // Deduplicate: if multiple phrases match at the same position,
        // keep only the longest one (e.g., "new paragraph" wins over "new line").
        var deduplicated: [LocatedCommand] = []
        var lastEnd: String.Index? = nil
        for item in located {
            if let end = lastEnd, item.range.lowerBound < end {
                // Overlapping — skip this one (the previous was longer due to sort order
                // of phrases within each pattern: longer phrases come first).
                continue
            }
            deduplicated.append(item)
            lastEnd = item.range.upperBound
        }

        return deduplicated
    }

    /// Build a regex that matches a phrase only at a sentence boundary.
    private func buildBoundaryRegex(for phrase: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        // Command must be at start of string or preceded by [.!?] (with optional space) or newline.
        let pattern = "(?:^|(?<=[.!?]\\s)|(?<=[.!?\\n]))\(escaped)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Clean up text after command replacement: collapse double spaces, trim lines.
    private func cleanupText(_ text: String) -> String {
        var result = text

        // Collapse multiple spaces into one (but preserve newlines)
        result = result.replacingOccurrences(
            of: " {2,}",
            with: " ",
            options: .regularExpression
        )

        // Trim each line
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        result = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")

        // Trim leading/trailing whitespace but preserve intentional newlines.
        // Only strip trailing newlines if there's actual text content.
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? result : trimmed
    }
}
