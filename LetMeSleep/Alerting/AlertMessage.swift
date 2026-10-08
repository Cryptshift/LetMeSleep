import Foundation

/// Builds the Discord message text from the user's template.
enum AlertMessage {
    static let levelPlaceholder = "{db}"
    static let secondsPlaceholder = "{seconds}"

    static let defaultTemplate =
        "It's getting pretty loud: about {db} dB for the last {seconds} seconds. Mind keeping it down? 🙏"

    /// Discord rejects message content longer than this.
    static let maxLength = 2000

    /// Fills in `{db}` (rounded dBFS level) and `{seconds}` (whole seconds).
    /// Falls back to the default template if the user's template is blank.
    static func render(template: String, level: Float, duration: TimeInterval) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? defaultTemplate : trimmed
        let decibels = level.isFinite ? Int(level.rounded()) : Int(DecibelMath.floor)
        let seconds = duration.isFinite ? max(0, Int(duration.rounded())) : 0
        let text = source
            .replacingOccurrences(of: levelPlaceholder, with: String(decibels))
            .replacingOccurrences(of: secondsPlaceholder, with: String(seconds))
        return String(text.prefix(maxLength))
    }
}
