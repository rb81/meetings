import Foundation

/// Splits a status such as "Transcribing the recording… 42%" into its words and a progress fraction, so progress
/// can be drawn as a bar instead of a number that keeps changing in the text.
enum StatusText {
    static func parse(_ status: String) -> (text: String, progress: Double?) {
        guard let match = status.firstMatch(of: /\s*(\d{1,3})\s?%\s*$/), let percent = Double(match.1) else {
            return (status, nil)
        }
        let text = String(status[..<match.range.lowerBound])
        return (text, min(1, max(0, percent / 100)))
    }
}
