import Foundation

enum AudioTrack: String, Codable, Sendable {
    case mic
    case system
}

/// One spoken word and when it was said, in seconds from the start of the recording.
struct SegmentWord: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var track: AudioTrack
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speakerID: String?
    var cleaned: String?
    /// Word timings, kept so a line can be cut where the speaker changes. Nil for older transcripts.
    var words: [SegmentWord]?
    /// True once you've moved this line to a speaker yourself, so identifying speakers again keeps your choice.
    var pinned: Bool?

    var displayText: String { cleaned ?? text }
}

struct TranscriptFile: Codable, Sendable {
    var version = 2
    var segments: [TranscriptSegment] = []
    var speakerNames: [String: String] = [:]
    /// True for in-person meetings, where the microphone carries the whole room instead of one person.
    var mixedMic = false
    /// Names heard in the conversation that probably belong to a speaker, offered but never applied by themselves.
    var suggestedNames: [String: String] = [:]

    static func defaultName(for speakerID: String) -> String {
        speakerID.hasPrefix("S") ? "Speaker \(speakerID.dropFirst())" : speakerID
    }

    /// Microphone lines are "You" in online meetings. In person they are the room, split into numbered speakers.
    func label(for segment: TranscriptSegment) -> String {
        guard let id = segment.speakerID else {
            if segment.track == .mic { return mixedMic ? "Room" : "You" }
            return "Others"
        }
        return speakerNames[id] ?? Self.defaultName(for: id)
    }

    /// The next unused speaker ID, for adding a speaker by hand.
    var nextSpeakerID: String {
        let highest = speakerIDs.compactMap { Int($0.dropFirst()) }.max() ?? 0
        return "S\(highest + 1)"
    }

    func name(for speakerID: String) -> String {
        speakerNames[speakerID] ?? Self.defaultName(for: speakerID)
    }

    var speakerIDs: [String] {
        Array(Set(segments.compactMap(\.speakerID))).sorted { lhs, rhs in
            (Int(lhs.dropFirst()) ?? 0) < (Int(rhs.dropFirst()) ?? 0)
        }
    }

    var hasCleanedText: Bool { segments.contains { $0.cleaned != nil } }

    /// The line spoken most recently at `time`, or the first line if the flag came before anyone spoke.
    func segment(near time: TimeInterval) -> TranscriptSegment? {
        segments.filter { $0.start <= time }.max { $0.start < $1.start }
            ?? segments.min { $0.start < $1.start }
    }

    /// Flags follow their line by ID, so cleaning up the text never detaches them.
    func segment(for bookmark: Bookmark) -> TranscriptSegment? {
        if let id = bookmark.segmentID {
            return segments.first { $0.id == id }
        }
        return segment(near: bookmark.time)
    }

    func text(for bookmark: Bookmark, useCleaned: Bool = true) -> String? {
        guard let segment = segment(for: bookmark) else { return bookmark.excerpt }
        return useCleaned ? segment.displayText : segment.text
    }

    func lines(useCleaned: Bool = true) -> [String] {
        segments.map { segment in
            let text = useCleaned ? segment.displayText : segment.text
            return "[\(Format.clock(segment.start))] \(label(for: segment)): \(text)"
        }
    }

    func plainText(useCleaned: Bool = true) -> String {
        lines(useCleaned: useCleaned).joined(separator: "\n")
    }
}

extension TranscriptFile {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
        segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        speakerNames = try container.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        mixedMic = try container.decodeIfPresent(Bool.self, forKey: .mixedMic) ?? false
        suggestedNames = try container.decodeIfPresent([String: String].self, forKey: .suggestedNames) ?? [:]
    }
}

/// Drops microphone lines that are really the other participants' voices coming out of the speakers.
enum EchoFilter {
    private static let minimumWords = 6
    private static let overlapThreshold = 0.8

    static func isEcho(_ mic: TranscriptSegment, of system: TranscriptSegment) -> Bool {
        guard mic.track == .mic, system.track == .system else { return false }
        guard mic.start <= system.end + 4, mic.end >= system.start - 1 else { return false }

        let micWords = words(in: mic.text)
        let systemWords = words(in: system.text)
        guard micWords.count >= minimumWords else { return false }

        let shared = micWords.intersection(systemWords).count
        return Double(shared) / Double(micWords.count) >= overlapThreshold
    }

    private static func words(in text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init))
    }
}
