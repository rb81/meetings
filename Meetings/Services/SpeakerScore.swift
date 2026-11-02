import Foundation

/// Measures how well speakers were separated, against a hand-labelled reference. Used by the tests to tune
/// the speaker pipeline on real recordings; the app itself never needs a reference.
enum SpeakerScore {
    struct Breakdown: Equatable {
        /// Seconds of reference speech.
        var speech: Double = 0
        /// Reference speech nobody was heard saying.
        var missed: Double = 0
        /// Speech heard where the reference has none.
        var falseAlarm: Double = 0
        /// Speech given to the wrong person.
        var confusion: Double = 0

        /// Diarization error rate: the share of reference speech that was missed, invented, or misattributed.
        var der: Double { speech > 0 ? (missed + falseAlarm + confusion) / speech : 0 }
    }

    static let frameSeconds = 0.01

    /// Diarization error rate with the best one-to-one match between reference and hypothesis speakers, so the
    /// numbering doesn't matter. Overlapping speech counts each speaker. Frames within `collar` seconds of a
    /// reference speaker change are skipped, as is standard.
    static func der(
        reference: [SpeakerAssignment.Turn],
        hypothesis: [SpeakerAssignment.Turn],
        collar: Double = 0
    ) -> Breakdown {
        let end = (reference + hypothesis).map(\.end).max() ?? 0
        let frames = Int((end / frameSeconds).rounded(.up))
        guard frames > 0 else { return Breakdown() }

        let refIDs = Array(Set(reference.map(\.speaker))).sorted()
        let hypIDs = Array(Set(hypothesis.map(\.speaker))).sorted()
        let ref = activity(reference, ids: refIDs, frames: frames)
        let hyp = activity(hypothesis, ids: hypIDs, frames: frames)

        var skip = [Bool](repeating: false, count: frames)
        if collar > 0 {
            let reach = Int((collar / frameSeconds).rounded())
            for turn in reference {
                for edge in [turn.start, turn.end] {
                    let center = Int((edge / frameSeconds).rounded())
                    for frame in max(0, center - reach)..<min(frames, center + reach) { skip[frame] = true }
                }
            }
        }

        var overlap = [[Double]](repeating: [Double](repeating: 0, count: refIDs.count), count: hypIDs.count)
        for frame in 0..<frames where !skip[frame] {
            for h in hypIDs.indices where hyp[h][frame] {
                for r in refIDs.indices where ref[r][frame] { overlap[h][r] += 1 }
            }
        }
        let mapping = bestMapping(overlap)

        var result = Breakdown()
        for frame in 0..<frames where !skip[frame] {
            let refCount = refIDs.indices.filter { ref[$0][frame] }.count
            let hypCount = hypIDs.indices.filter { hyp[$0][frame] }.count
            let correct = hypIDs.indices.filter { h in
                hyp[h][frame] && mapping[h].map { ref[$0][frame] } == true
            }.count
            result.speech += Double(refCount)
            result.missed += Double(max(0, refCount - hypCount))
            result.falseAlarm += Double(max(0, hypCount - refCount))
            result.confusion += Double(min(refCount, hypCount) - correct)
        }
        result.speech *= frameSeconds
        result.missed *= frameSeconds
        result.falseAlarm *= frameSeconds
        result.confusion *= frameSeconds
        return result
    }

    /// The share of words given to the wrong person, after the best one-to-one match between speaker labels.
    /// Words with no hypothesis speaker count as wrong.
    static func wordError(reference: [String], hypothesis: [String?]) -> Double {
        guard !reference.isEmpty, reference.count == hypothesis.count else { return 0 }
        let refIDs = Array(Set(reference)).sorted()
        let hypIDs = Array(Set(hypothesis.compactMap { $0 })).sorted()
        var overlap = [[Double]](repeating: [Double](repeating: 0, count: refIDs.count), count: hypIDs.count)
        for (r, h) in zip(reference, hypothesis) {
            guard let h, let hi = hypIDs.firstIndex(of: h), let ri = refIDs.firstIndex(of: r) else { continue }
            overlap[hi][ri] += 1
        }
        let mapping = bestMapping(overlap)
        var wrong = 0
        for (r, h) in zip(reference, hypothesis) {
            guard let h, let hi = hypIDs.firstIndex(of: h), let mapped = mapping[hi], refIDs[mapped] == r else {
                wrong += 1
                continue
            }
        }
        return Double(wrong) / Double(reference.count)
    }

    /// Reads speaker turns from RTTM, the usual format for labelled meetings:
    /// `SPEAKER <file> <channel> <start> <duration> <NA> <NA> <speaker> <NA> <NA>`.
    static func parseRTTM(_ text: String) -> [SpeakerAssignment.Turn] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 8, fields[0] == "SPEAKER",
                  let start = Double(fields[3]), let duration = Double(fields[4]), duration > 0
            else { return nil }
            return SpeakerAssignment.Turn(speaker: String(fields[7]), start: start, end: start + duration)
        }
    }

    // MARK: - Helpers

    private static func activity(_ turns: [SpeakerAssignment.Turn], ids: [String], frames: Int) -> [[Bool]] {
        var result = [[Bool]](repeating: [Bool](repeating: false, count: frames), count: ids.count)
        for turn in turns {
            guard let index = ids.firstIndex(of: turn.speaker) else { continue }
            let low = max(0, Int((turn.start / frameSeconds).rounded()))
            let high = min(frames, Int((turn.end / frameSeconds).rounded()))
            if low < high { for frame in low..<high { result[index][frame] = true } }
        }
        return result
    }

    /// For each hypothesis speaker, the reference speaker it matches, maximising total overlap. Exact for up to
    /// twelve reference speakers, greedy beyond that.
    static func bestMapping(_ overlap: [[Double]]) -> [Int?] {
        let hyps = overlap.count
        let refs = overlap.first?.count ?? 0
        guard hyps > 0, refs > 0 else { return [Int?](repeating: nil, count: hyps) }

        guard refs <= 12 else {
            var result = [Int?](repeating: nil, count: hyps)
            var used = Set<Int>()
            let pairs = (0..<hyps).flatMap { h in (0..<refs).map { (h, $0) } }
                .sorted { overlap[$0.0][$0.1] > overlap[$1.0][$1.1] }
            for (h, r) in pairs where result[h] == nil && !used.contains(r) && overlap[h][r] > 0 {
                result[h] = r
                used.insert(r)
            }
            return result
        }

        // best[h][mask]: the most overlap from hypothesis speakers h... using reference speakers not in mask.
        let masks = 1 << refs
        var best = [[Double]](repeating: [Double](repeating: 0, count: masks), count: hyps + 1)
        var choice = [[Int]](repeating: [Int](repeating: -1, count: masks), count: hyps)
        for h in stride(from: hyps - 1, through: 0, by: -1) {
            for mask in 0..<masks {
                var top = best[h + 1][mask]
                var pick = -1
                for r in 0..<refs where mask & (1 << r) == 0 && overlap[h][r] > 0 {
                    let value = overlap[h][r] + best[h + 1][mask | (1 << r)]
                    if value > top {
                        top = value
                        pick = r
                    }
                }
                best[h][mask] = top
                choice[h][mask] = pick
            }
        }

        var result = [Int?](repeating: nil, count: hyps)
        var mask = 0
        for h in 0..<hyps {
            let pick = choice[h][mask]
            if pick >= 0 {
                result[h] = pick
                mask |= 1 << pick
            }
        }
        return result
    }
}
