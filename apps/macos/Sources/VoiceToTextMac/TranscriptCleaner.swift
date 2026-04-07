import Foundation

/// Cleans raw transcripts according to the active dictation mode.
///
/// - `Terminal` mode: preserves intent closely with minimal smoothing,
///   safe for CLI prompts and AI tool inputs.
/// - `Writing` mode: cleans punctuation, removes filler words,
///   and makes prose more readable.
public struct TranscriptCleaner: Sendable {

    public init() {}

    /// Clean a raw transcript according to the given mode.
    public func clean(_ rawText: String, mode: DictationMode) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        switch mode {
        case .terminal:
            return cleanForTerminal(trimmed)
        case .writing:
            return cleanForWriting(trimmed)
        }
    }

    // MARK: - Terminal Mode

    /// Terminal mode: preserve intent closely, minimal smoothing.
    /// - Collapse repeated whitespace
    /// - Strip leading/trailing whitespace per line
    /// - Remove filler words only when they start a sentence
    /// - Do NOT alter casing or punctuation aggressively
    private func cleanForTerminal(_ text: String) -> String {
        var result = text

        // Collapse multiple spaces into one
        result = collapseWhitespace(result)

        // Remove leading filler words only (keep mid-sentence fillers
        // since they may be intentional in a CLI prompt context)
        result = removeLeadingFillers(result)

        // Trim each line
        result = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Writing Mode

    /// Writing mode: clean more aggressively for prose.
    /// - Remove filler words throughout
    /// - Fix sentence capitalization
    /// - Normalize punctuation spacing
    /// - Collapse whitespace
    private func cleanForWriting(_ text: String) -> String {
        var result = text

        // Remove filler words throughout the text
        result = removeFillerWords(result)

        // Collapse multiple spaces
        result = collapseWhitespace(result)

        // Normalize punctuation spacing (no space before period/comma/etc.)
        result = normalizePunctuation(result)

        // Capitalize first letter of each sentence
        result = capitalizeSentences(result)

        // Trim each line
        result = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Filler Words

    private static let fillerPatterns: [String] = [
        "um", "uh", "erm", "er", "ah", "hmm",
        "you know", "I mean", "like", "so",
        "basically", "actually", "literally",
        "sort of", "kind of",
    ]

    /// Remove filler words that appear at the start of the text.
    private func removeLeadingFillers(_ text: String) -> String {
        var result = text
        var changed = true

        while changed {
            changed = false
            let lower = result.lowercased()
            for filler in Self.fillerPatterns {
                if lower.hasPrefix(filler) {
                    let afterFiller = result.index(result.startIndex, offsetBy: filler.count)
                    let rest = result[afterFiller...]

                    // Only strip if followed by whitespace, comma, or end of string
                    if rest.isEmpty {
                        result = ""
                        changed = true
                        break
                    }

                    let nextChar = rest.first!
                    if nextChar == " " || nextChar == "," {
                        result = String(rest).trimmingCharacters(in: .whitespaces)
                        // Also strip a leading comma left behind
                        if result.hasPrefix(",") {
                            result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
                        }
                        changed = true
                        break
                    }
                }
            }
        }

        return result
    }

    /// Remove filler words throughout the text (Writing mode).
    private func removeFillerWords(_ text: String) -> String {
        var result = text

        for filler in Self.fillerPatterns {
            // Match filler words at word boundaries (case-insensitive)
            // Use a simple approach: split and filter
            result = removeWordPattern(filler, from: result)
        }

        return result
    }

    /// Remove a specific word/phrase pattern from text at word boundaries.
    private func removeWordPattern(_ pattern: String, from text: String) -> String {
        // Build a regex that matches the pattern at word boundaries
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        // Match: (start or whitespace) + pattern + (comma/space/period/end)
        // Case insensitive
        guard let regex = try? NSRegularExpression(
            pattern: "(?<=^|\\s)\(escaped)(?=[\\s,.]|$)",
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        var result = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")

        // Clean up leftover double spaces and orphaned commas
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = collapseWhitespace(result)

        return result
    }

    // MARK: - Punctuation

    /// Remove spaces before punctuation marks and ensure one space after.
    private func normalizePunctuation(_ text: String) -> String {
        var result = text

        // Remove space before period, comma, question mark, exclamation
        for mark in [".", ",", "?", "!", ";", ":"] {
            result = result.replacingOccurrences(of: " \(mark)", with: mark)
        }

        // Ensure single space after sentence-ending punctuation if followed by a letter
        guard let afterPunctuation = try? NSRegularExpression(
            pattern: "([.!?])([A-Za-z])",
            options: []
        ) else {
            return result
        }

        let range = NSRange(result.startIndex..., in: result)
        result = afterPunctuation.stringByReplacingMatches(
            in: result,
            range: range,
            withTemplate: "$1 $2"
        )

        return result
    }

    // MARK: - Capitalization

    /// Capitalize the first letter of each sentence.
    private func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = Array(text)
        var capitalizeNext = true

        for i in result.indices {
            let char = result[i]

            if capitalizeNext && char.isLetter {
                result[i] = Character(char.uppercased())
                capitalizeNext = false
            } else if char == "." || char == "!" || char == "?" {
                capitalizeNext = true
            } else if char == "\n" {
                capitalizeNext = true
            }
        }

        return String(result)
    }

    // MARK: - Whitespace

    /// Collapse runs of whitespace into a single space.
    private func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
    }
}
