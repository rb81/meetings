import Foundation

/// Small, careful fixes to speaker labels using Apple's on-device model. Nothing leaves the Mac.
///
/// Language models are poor at deciding who spoke from the text alone, so this never relabels whole lines.
/// It does two narrow things: where the voice changes, it asks whether one to three words at the edge of a line
/// clearly finish the other person's sentence, and it looks for names people say ("I'm Dana", "thanks, Dana")
/// to suggest for a speaker. Words are never changed, and suggested names are only offered, never applied.
enum SpeakerPolish {
    struct Boundary: Equatable {
        enum Direction: Equatable {
            /// The first words of the later line finish the earlier speaker's sentence.
            case headToBefore
            /// The last words of the earlier line start the later speaker's sentence.
            case tailToAfter
        }

        let before: UUID
        let after: UUID
        let count: Int
        let direction: Direction
    }

    static let maxWords = 3

    struct Result {
        var segments: [TranscriptSegment]
        var suggestedNames: [String: String] = [:]
        var moved = 0
    }

    /// Runs the enabled steps. Any failure just leaves the transcript as it was.
    static func run(
        segments: [TranscriptSegment],
        speakerNames: [String: String],
        model: any LanguageModel,
        tidy: Bool,
        suggest: Bool
    ) async -> Result {
        var result = Result(segments: segments)
        let names: (String) -> String = { speakerNames[$0] ?? TranscriptFile.defaultName(for: $0) }

        if tidy {
            let all = candidates(in: segments)
            var start = 0
            while start < all.count {
                var batch: [Boundary] = []
                var size = 0
                var end = start
                while end < all.count, batch.count < 8 {
                    let text = prompt(for: [all[end]], in: result.segments, names: names)
                    guard batch.isEmpty || size + text.count < model.promptBudget - 1_000 else { break }
                    batch.append(all[end])
                    size += text.count
                    end += 1
                }
                start = end
                let question = prompt(for: batch, in: result.segments, names: names)
                guard !question.isEmpty,
                      let reply = try? await model.complete(system: boundarySystem, user: question, json: true)
                else { continue }
                for number in parseMoves(reply).sorted() where (1...batch.count).contains(number) {
                    let updated = apply(batch[number - 1], to: result.segments)
                    if updated != result.segments {
                        result.segments = updated
                        result.moved += 1
                    }
                }
            }
        }

        if suggest {
            let excerpt = nameExcerpt(result.segments, limit: max(1_000, model.promptBudget - 1_000))
            let speakers = Set(result.segments.compactMap { $0.track == .mic ? $0.speakerID : nil })
            if !excerpt.isEmpty, !speakers.isEmpty,
               let reply = try? await model.complete(system: nameSystem, user: excerpt, json: true) {
                let transcript = result.segments.map(\.text).joined(separator: " ")
                result.suggestedNames = validNames(reply, transcript: transcript, speakers: speakers, named: speakerNames)
            }
        }
        return result
    }

    // MARK: - Speaker changes

    /// Places where the voice changes between two room lines and a few words look like they're on the wrong side.
    static func candidates(in segments: [TranscriptSegment], maxGap: Double = 1.0) -> [Boundary] {
        let mic = segments.filter { $0.track == .mic && $0.speakerID != nil }.sorted { $0.start < $1.start }
        var result: [Boundary] = []

        for (a, b) in zip(mic, mic.dropFirst()) {
            guard a.speakerID != b.speakerID, b.start - a.end <= maxGap, a.pinned != true, b.pinned != true,
                  let first = a.words, let second = b.words, first.count >= 2, second.count >= 2
            else { continue }

            if !endsSentence(first[first.count - 1].text),
               let k = second.prefix(maxWords).firstIndex(where: { endsClause($0.text) }),
               second.count - (k + 1) >= 2 {
                result.append(Boundary(before: a.id, after: b.id, count: k + 1, direction: .headToBefore))
            } else if let k = first.dropLast().lastIndex(where: { endsSentence($0.text) }),
                      first.count - (k + 1) <= maxWords, k + 1 >= 2,
                      startsLowercase(second[0].text) || !endsSentence(first[first.count - 1].text) {
                result.append(Boundary(before: a.id, after: b.id, count: first.count - (k + 1), direction: .tailToAfter))
            }
        }
        return result
    }

    /// Moves the words across the speaker change. Both lines lose their cleaned text, since it no longer matches.
    static func apply(_ boundary: Boundary, to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard let i = segments.firstIndex(where: { $0.id == boundary.before }),
              let j = segments.firstIndex(where: { $0.id == boundary.after }),
              var first = segments[i].words, var second = segments[j].words
        else { return segments }

        switch boundary.direction {
        case .headToBefore:
            guard second.count > boundary.count else { return segments }
            first += second.prefix(boundary.count)
            second.removeFirst(boundary.count)
        case .tailToAfter:
            guard first.count > boundary.count else { return segments }
            second.insert(contentsOf: first.suffix(boundary.count), at: 0)
            first.removeLast(boundary.count)
        }

        var result = segments
        result[i] = reworded(segments[i], first)
        result[j] = reworded(segments[j], second)
        return result
    }

    private static func reworded(_ segment: TranscriptSegment, _ words: [SegmentWord]) -> TranscriptSegment {
        var copy = segment
        copy.words = words
        copy.text = words.map(\.text).joined(separator: " ")
        copy.cleaned = nil
        copy.start = words.first?.start ?? segment.start
        copy.end = words.last?.end ?? segment.end
        return copy
    }

    /// One question for a batch of speaker changes, as the model sees it.
    static func prompt(for boundaries: [Boundary], in segments: [TranscriptSegment], names: (String) -> String) -> String {
        let byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parts: [String] = []
        for (number, boundary) in boundaries.enumerated() {
            guard let a = byID[boundary.before], let b = byID[boundary.after],
                  let first = a.words, let second = b.words,
                  let speakerA = a.speakerID, let speakerB = b.speakerID
            else { continue }

            let nameA = names(speakerA)
            let nameB = names(speakerB)
            let lineA: String
            let lineB: String
            let question: String
            switch boundary.direction {
            case .headToBefore:
                let moved = second.prefix(boundary.count).map(\.text).joined(separator: " ")
                lineA = first.map(\.text).joined(separator: " ")
                lineB = "[\(moved)] " + second.dropFirst(boundary.count).map(\.text).joined(separator: " ")
                question = "Were the words in brackets really said by \(nameA), finishing their sentence?"
            case .tailToAfter:
                let moved = first.suffix(boundary.count).map(\.text).joined(separator: " ")
                lineA = first.dropLast(boundary.count).map(\.text).joined(separator: " ") + " [\(moved)]"
                lineB = second.map(\.text).joined(separator: " ")
                question = "Were the words in brackets really said by \(nameB), starting their sentence?"
            }
            parts.append("Case \(number + 1)\n\(nameA): \(lineA)\n\(nameB): \(lineB)\n\(question)")
        }
        return parts.joined(separator: "\n\n")
    }

    static let boundarySystem = """
    You check who said what in a meeting transcript. The speaker labels come from a voice model that is sometimes \
    off by a word or two right where one person stops and the next starts. For each case, decide whether the words \
    in brackets belong to the other speaker. Say yes only when the sentence clearly reads that way, for example a \
    sentence that is cut off and finished by the bracketed words. When unsure, say no. Never rewrite anything. \
    Reply with JSON only, in the form {"yes": [1, 3]}, listing the case numbers that should move.
    """

    /// The case numbers (counting from 1) the model said to move.
    static func parseMoves(_ reply: String) -> Set<Int> {
        guard let object = jsonObject(in: reply), let values = object["yes"] as? [Any] else { return [] }
        return Set(values.compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0) } })
    }

    // MARK: - Names

    private static let nameCues = try! NSRegularExpression(
        pattern: #"\b(i'm|i am|my name is|my name's|this is|it's|thanks|thank you|hi|hey|hello|over to you|go ahead|what do you think)\b"#,
        options: [.caseInsensitive]
    )

    /// The lines where a name is most likely to come up, with the line after each, to keep the question short.
    static func nameExcerpt(_ segments: [TranscriptSegment], limit: Int = 5_000) -> String {
        let mic = segments.filter { $0.track == .mic && $0.speakerID != nil }.sorted { $0.start < $1.start }
        var picked = IndexSet()
        for (index, segment) in mic.enumerated() {
            let text = segment.text
            let range = NSRange(text.startIndex..., in: text)
            guard nameCues.firstMatch(in: text, range: range) != nil else { continue }
            picked.insert(index)
            if index + 1 < mic.count { picked.insert(index + 1) }
            if index > 0 { picked.insert(index - 1) }
        }

        var lines: [String] = []
        var used = 0
        for index in picked {
            let segment = mic[index]
            let line = "\(segment.speakerID ?? "?"): \(segment.text)"
            guard used + line.count < limit else { break }
            lines.append(line)
            used += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    static let nameSystem = """
    You read lines from one meeting transcript. Each line starts with a speaker ID such as S1. Find a speaker's name \
    only when the transcript makes it certain: the speaker says their own name ("I'm Dana", "this is Dana"), or \
    someone greets or thanks a person by name and that person answers in the very next line. Never guess from \
    anything else. Reply with JSON only, in the form {"names": {"S1": "Dana"}}, or {"names": {}} when nothing is certain.
    """

    /// Keeps only suggestions that are plausible names actually said in the meeting, for speakers who don't
    /// have a name yet. A name offered for two speakers is dropped for both.
    static func validNames(
        _ reply: String,
        transcript: String,
        speakers: Set<String>,
        named: [String: String]
    ) -> [String: String] {
        guard let object = jsonObject(in: reply), let raw = object["names"] as? [String: Any] else { return [:] }
        let taken = Set(named.values.map { $0.lowercased() })
        let spoken = Set(transcript.split { !$0.isLetter && $0 != "'" && $0 != "-" }.map(String.init))

        var result: [String: String] = [:]
        for (id, value) in raw {
            guard speakers.contains(id), named[id] == nil, let name = value as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let parts = trimmed.split(separator: " ").map(String.init)
            guard (1...3).contains(parts.count),
                  parts.allSatisfy({ $0.first?.isUppercase == true && spoken.contains($0) }),
                  !taken.contains(trimmed.lowercased()),
                  !["Speaker", "Room", "You", "I"].contains(parts[0])
            else { continue }
            result[id] = trimmed
        }

        let counts = Dictionary(grouping: result.values, by: { $0.lowercased() }).mapValues(\.count)
        return result.filter { counts[$0.value.lowercased()] == 1 }
    }

    // MARK: - Text helpers

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!".contains(last)
    }

    private static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!,".contains(last)
    }

    private static func startsLowercase(_ word: String) -> Bool {
        word.first?.isLowercase == true
    }

    private static func jsonObject(in text: String) -> [String: Any]? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
