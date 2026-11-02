import Foundation

/// Cuts a transcript line where the voice changes in the middle of it.
///
/// Lines are cut at pauses in speech, not at changes of speaker, so when one person starts talking right as
/// another finishes, both end up in one line under one name. The word timings let us cut it where the voice changed.
enum SegmentSplitter {
    private struct Run {
        var speaker: String?
        var words: [SegmentWord]

        var seconds: Double {
            guard let first = words.first, let last = words.last else { return 0 }
            return max(0, last.end - first.start)
        }
    }

    /// A stretch shorter than this is treated as noise in the voice detection and joined to its neighbour.
    static let minimumWords = 2
    static let minimumSeconds = 0.6

    /// The line as one or more lines. A line that doesn't change speaker comes back untouched.
    /// Pieces of a split line carry no speaker, because the caller is about to decide who they belong to.
    static func split(_ segment: TranscriptSegment, turns: [SpeakerAssignment.Turn]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return [segment] }
        return split(segment) { SpeakerAssignment.speaker(start: $0.start, end: $0.end, turns: turns, maxGap: 0.5) }
    }

    /// The same, with `voice` naming who said each word (nil when it can't tell).
    static func split(_ segment: TranscriptSegment, voice: (SegmentWord) -> String?) -> [TranscriptSegment] {
        guard let words = segment.words, words.count >= 4 else { return [segment] }

        let runs = runs(for: words, voice: voice)
        guard runs.count > 1 else { return [segment] }

        return runs.enumerated().map { index, run in
            var piece = segment
            piece.id = index == 0 ? segment.id : UUID()
            piece.words = run.words
            piece.text = run.words.map(\.text).joined(separator: " ")
            piece.cleaned = nil
            piece.speakerID = nil
            piece.start = index == 0 ? segment.start : run.words[0].start
            piece.end = index == runs.count - 1 ? segment.end : run.words[run.words.count - 1].end
            return piece
        }
    }

    private static func runs(for words: [SegmentWord], voice: (SegmentWord) -> String?) -> [Run] {
        var speakers: [String?] = words.map(voice)

        // Words the model missed take the voice of the words around them.
        var carried: String?
        for index in speakers.indices {
            if speakers[index] == nil { speakers[index] = carried } else { carried = speakers[index] }
        }
        carried = nil
        for index in speakers.indices.reversed() {
            if speakers[index] == nil { speakers[index] = carried } else { carried = speakers[index] }
        }

        var runs: [Run] = []
        for (word, speaker) in zip(words, speakers) {
            if let last = runs.last, last.speaker == speaker {
                runs[runs.count - 1].words.append(word)
            } else {
                runs.append(Run(speaker: speaker, words: [word]))
            }
        }

        while runs.count > 1, let weak = runs.firstIndex(where: isWeak) {
            let target: Int
            if weak == 0 {
                target = 1
            } else if weak == runs.count - 1 {
                target = weak - 1
            } else if runs[weak - 1].speaker == runs[weak + 1].speaker {
                target = weak - 1
            } else {
                target = runs[weak - 1].seconds >= runs[weak + 1].seconds ? weak - 1 : weak + 1
            }

            let low = min(weak, target)
            let high = max(weak, target)
            runs[low].words += runs[high].words
            runs[low].speaker = runs[target].speaker
            runs.remove(at: high)
            runs = joined(runs)
        }
        return runs
    }

    private static func isWeak(_ run: Run) -> Bool {
        run.words.count < minimumWords || run.seconds < minimumSeconds
    }

    /// Neighbouring stretches by the same voice become one.
    private static func joined(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs {
            if let last = result.last, last.speaker == run.speaker {
                result[result.count - 1].words += run.words
            } else {
                result.append(run)
            }
        }
        return result
    }
}
