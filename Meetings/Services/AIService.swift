import Foundation

/// Cleans, summarizes, and answers questions about a transcript.
///
/// Every request stays within the model's prompt budget. Short meetings go in one request, as before.
/// Long ones are split: notes are written per part and then merged, and Ask reads only the parts that match the question.
struct AIService: Sendable {
    let model: LanguageModel

    /// Cleans transcript lines in batches. Returns the cleaned text by line index.
    func clean(lines: [(index: Int, speaker: String, text: String)]) async throws -> [Int: String] {
        let system = """
        You clean up speech-to-text transcript lines. Fix punctuation and capitalization, correct obvious \
        recognition mistakes, and remove filler words, false starts and stutters. Keep each speaker's meaning, \
        wording and language. Never summarize, merge, split, add or drop lines. \
        Reply with JSON only in exactly this shape: {"lines": [{"i": number, "text": string}]} \
        with one entry for every input index.
        """

        // Each batch's input and reply are about the same size, so a batch gets half the budget.
        let sizes = lines.map { $0.text.count + $0.speaker.count + 40 }
        var cleaned: [Int: String] = [:]

        for range in Chunker.ranges(sizes: sizes, limit: model.promptBudget / 2) {
            let batch = Array(lines[range])
            let payload = batch.map { ["i": $0.index, "speaker": $0.speaker, "text": $0.text] as [String: Any] }
            let input = String(
                data: try JSONSerialization.data(withJSONObject: payload),
                encoding: .utf8
            ) ?? "[]"

            let reply = try await model.complete(system: system, user: input, json: true)
            guard let data = Self.jsonData(in: reply),
                  let parsed = try? JSONDecoder().decode(CleanReply.self, from: data)
            else { continue }

            let originals = Dictionary(uniqueKeysWithValues: batch.map { ($0.index, $0.text) })
            for line in parsed.lines {
                guard let original = originals[line.i], Self.isFaithful(line.text, to: original) else { continue }
                cleaned[line.i] = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return cleaned
    }

    func makeNotes(
        title: String,
        attendees: [String],
        transcript: [String],
        userNotes: String,
        bookmarks: [String]
    ) async throws -> MeetingNotes {
        var context = "Meeting: \(title)\n"
        if !attendees.isEmpty { context += "Invited: \(attendees.joined(separator: ", "))\n" }
        if !userNotes.isEmpty { context += "\nNotes typed by the user:\n\(userNotes)\n" }
        if !bookmarks.isEmpty { context += "\nMoments the user flagged:\n\(bookmarks.joined(separator: "\n"))\n" }

        let room = max(
            model.promptBudget / 3,
            model.promptBudget - Self.notesSystem.count - context.count - 200
        )
        let sizes = transcript.map { $0.count + 1 }
        let reply: String

        if sizes.reduce(0, +) <= room {
            let user = context + "\nTranscript:\n" + transcript.joined(separator: "\n")
            reply = try await model.complete(system: Self.notesSystem, user: user, json: true)
        } else {
            var blocks: [String] = []
            for range in Chunker.ranges(sizes: sizes, limit: room) {
                let part = transcript[range].joined(separator: "\n")
                let user = "Meeting: \(title)\n\nTranscript part:\n\(part)"
                blocks.append(try await model.complete(system: Self.partSystem, user: user, json: false))
            }

            while blocks.count > 1, blocks.map(\.count).reduce(0, +) > room {
                var merged: [String] = []
                for range in Chunker.ranges(sizes: blocks.map { $0.count + 2 }, limit: room) {
                    if range.count == 1 {
                        merged.append(blocks[range.lowerBound])
                    } else {
                        let user = blocks[range].joined(separator: "\n\n---\n\n")
                        merged.append(try await model.complete(system: Self.mergeSystem, user: user, json: false))
                    }
                }
                // Stop if merging no longer shrinks anything, so a very large meeting can't loop forever.
                guard merged.count < blocks.count else { break }
                blocks = merged
            }

            let user = context + "\nNotes on consecutive parts of the meeting:\n" + blocks.joined(separator: "\n\n")
            reply = try await model.complete(system: Self.notesSystem, user: user, json: true)
        }

        guard let data = Self.jsonData(in: reply),
              let parsed = try? JSONDecoder().decode(NotesReply.self, from: data)
        else { throw AIError.invalidResponse }

        return MeetingNotes(
            summary: parsed.summary,
            decisions: parsed.decisions ?? [],
            actionItems: (parsed.actionItems ?? []).map { ActionItem(task: $0.task, owner: $0.owner, due: $0.due) },
            generatedAt: .now,
            model: model.label
        )
    }

    func answer(question: String, transcript: [String], notes: MeetingNotes?) async throws -> String {
        let system = """
        You answer questions about one meeting using only the transcript excerpts and notes provided. \
        If the answer isn't in them, say so plainly. The excerpts may be only part of the meeting, so say when \
        the answer could be elsewhere in it. Be concise and quote speakers by name when it helps.
        """

        var header = ""
        if let notes {
            header += "Notes:\n\(notes.summary)\n\n"
        }
        let room = max(
            model.promptBudget / 2,
            model.promptBudget - system.count - header.count - question.count - 300
        )
        let excerpts = Self.relevantExcerpts(from: transcript, question: question, limit: room)
        let user = header + "Transcript:\n" + excerpts + "\n\nQuestion: \(question)"
        return try await model.complete(system: system, user: user, json: false)
    }

    // MARK: - Prompts

    private static let notesSystem = """
    You write meeting notes from a speech-to-text transcript. Stay faithful to what was said and never invent \
    facts, owners or dates. The transcript may contain recognition errors; use context to read past them. \
    The input is either the full transcript or notes on consecutive parts of one long meeting. \
    Reply with JSON only, no commentary, in exactly this shape: \
    {"summary": string (3 to 6 sentences), "decisions": [string], \
    "action_items": [{"task": string, "owner": string or null, "due": string or null}]}. \
    Use empty arrays when there are no decisions or action items. Write in the language of the transcript.
    """

    private static let partSystem = """
    You summarize one part of a meeting transcript. Use only what this part says, and never invent facts, \
    owners or dates. Write plain text with these headings, leaving out any heading with nothing under it: \
    "Summary:" (2 to 4 sentences), "Decisions:" (one per line), "Action items:" (one per line, with the owner \
    and due date when they were stated). Write in the language of the transcript.
    """

    private static let mergeSystem = """
    You combine summaries of consecutive parts of one meeting into a single summary in the same format: \
    "Summary:", "Decisions:", "Action items:". Keep every decision and action item, remove repeats, and never \
    invent facts. Write in the language of the input.
    """

    // MARK: - Helpers

    /// A cleaned line must not be empty, must not grow much, and must not shrink to almost nothing.
    private static func isFaithful(_ cleaned: String, to original: String) -> Bool {
        let text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard Double(text.count) <= Double(original.count) * 1.5 + 20 else { return false }
        return original.count < 40 || Double(text.count) >= Double(original.count) * 0.35
    }

    private static let stopWords: Set<String> = [
        "the", "and", "what", "did", "was", "were", "that", "this", "with", "about", "have", "has",
        "who", "when", "where", "how", "why", "for", "are", "from", "they", "their", "there", "said", "does",
    ]

    /// Keeps the lines that best match the question, in meeting order. Lines are grouped into windows so each
    /// match brings its surroundings along.
    static func relevantExcerpts(from lines: [String], question: String, limit: Int) -> String {
        let sizes = lines.map { $0.count + 1 }
        if sizes.reduce(0, +) <= limit {
            return lines.joined(separator: "\n")
        }

        let terms = Set(
            words(in: question).filter { $0.count > 2 && !stopWords.contains($0) }
        )
        let windows = Chunker.ranges(sizes: sizes, limit: max(1, limit / 4))
        let scores: [Int] = windows.map { range in
            terms.intersection(words(in: lines[range].joined(separator: " "))).count
        }

        // Highest score first. Ties go to the earlier part, which usually holds the agenda.
        let ranked = windows.indices.sorted { lhs, rhs in
            scores[lhs] != scores[rhs] ? scores[lhs] > scores[rhs] : lhs < rhs
        }

        var chosen: [Int] = []
        var used = 0
        for index in ranked {
            let size = windows[index].reduce(0) { $0 + sizes[$1] }
            if used + size <= limit {
                chosen.append(index)
                used += size
            }
        }

        return chosen.sorted()
            .map { lines[windows[$0]].joined(separator: "\n") }
            .joined(separator: "\n[…]\n")
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private struct NotesReply: Decodable {
        struct Item: Decodable {
            let task: String
            let owner: String?
            let due: String?
        }

        let summary: String
        let decisions: [String]?
        let actionItems: [Item]?

        enum CodingKeys: String, CodingKey {
            case summary, decisions
            case actionItems = "action_items"
        }
    }

    private struct CleanReply: Decodable {
        struct Line: Decodable {
            let i: Int
            let text: String
        }

        let lines: [Line]
    }

    /// Models sometimes wrap JSON in code fences or add a sentence around it.
    private static func jsonData(in text: String) -> Data? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last else { return nil }
        return String(text[first...last]).data(using: .utf8)
    }
}

enum Chunker {
    /// Splits items into consecutive ranges whose sizes add up to at most `limit`.
    /// An item larger than the limit gets a range of its own.
    static func ranges(sizes: [Int], limit: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        var total = 0
        for (index, size) in sizes.enumerated() {
            if total + size > limit, index > start {
                result.append(start..<index)
                start = index
                total = 0
            }
            total += size
        }
        if start < sizes.count {
            result.append(start..<sizes.count)
        }
        return result
    }
}
