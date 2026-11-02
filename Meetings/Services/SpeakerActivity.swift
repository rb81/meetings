import FluidAudio
import Foundation

/// The speaker models used for in-person meetings. Both are NVIDIA's Nemotron 3 diarizer, which hears up to
/// eight voices and numbers them in the order they first speak. They differ only in how much audio they look at
/// per step: the live one answers within about three seconds, the careful one looks ten seconds at a time.
enum SpeakerModels {
    static let live = Nemotron3Config.fast32
    static let careful = Nemotron3Config.fast128
}

/// How likely each voice is to be speaking, every 10 ms. This is what the speaker model actually produces;
/// keeping it, instead of reducing it to turns straight away, lets each word be given to the voice that is
/// most clearly speaking while it is said, even when two people talk over each other.
struct SpeakerActivity: Sendable, Equatable {
    static let frameSeconds = 0.01

    let slots: Int
    private(set) var values: [Float]

    init(slots: Int = 8, values: [Float] = []) {
        self.slots = slots
        self.values = values
    }

    var frameCount: Int { values.count / slots }
    var duration: Double { Double(frameCount) * Self.frameSeconds }
    var isEmpty: Bool { frameCount == 0 }

    mutating func append(_ probabilities: [Float]) {
        values.append(contentsOf: probabilities)
    }

    func probability(frame: Int, slot: Int) -> Float {
        values[frame * slots + slot]
    }

    private func frames(from start: Double, to end: Double) -> Range<Int> {
        let low = max(0, Int((start / Self.frameSeconds).rounded(.down)))
        let high = min(frameCount, Int((end / Self.frameSeconds).rounded(.up)))
        return low..<max(low, high)
    }

    /// The average likelihood of each voice over a stretch of time.
    func average(start: Double, end: Double) -> [Float] {
        var sums = [Float](repeating: 0, count: slots)
        let range = frames(from: start, to: end)
        guard !range.isEmpty else { return sums }
        for frame in range {
            for slot in 0..<slots { sums[slot] += values[frame * slots + slot] }
        }
        return sums.map { $0 / Float(range.count) }
    }

    /// The voice most clearly speaking during `start...end`. If nobody is, the nearest voice within `maxGap`
    /// seconds takes it, because the model tends to miss the quiet edges of words.
    func voice(start: Double, end: Double, maxGap: Double = 0.5, minimum: Float = 0.2) -> Int? {
        let averages = average(start: start, end: end)
        if let best = averages.indices.max(by: { averages[$0] < averages[$1] }), averages[best] >= minimum {
            return best
        }
        return nearestVoice(start: start, end: end, maxGap: maxGap)
    }

    private func nearestVoice(start: Double, end: Double, maxGap: Double, threshold: Float = 0.5) -> Int? {
        let range = frames(from: start, to: end)
        let reach = Int(maxGap / Self.frameSeconds)
        for step in 1...max(1, reach) {
            for frame in [range.lowerBound - step, range.upperBound - 1 + step] where frame >= 0 && frame < frameCount {
                var best: Int?
                var bestValue = threshold
                for slot in 0..<slots where values[frame * slots + slot] > bestValue {
                    best = slot
                    bestValue = values[frame * slots + slot]
                }
                if let best { return best }
            }
        }
        return nil
    }

    /// When each voice speaks. A voice starts once it is more likely than `onset` and stops when it falls below
    /// `offset`, so a wobble around one threshold doesn't chop speech up. Gaps shorter than `bridge` are closed
    /// and stretches shorter than `minimum` are dropped.
    func turns(
        onset: Float = 0.5,
        offset: Float = 0.35,
        bridge: Double = 0.3,
        minimum: Double = 0.25
    ) -> [SpeakerAssignment.Turn] {
        var result: [SpeakerAssignment.Turn] = []
        let bridgeFrames = Int(bridge / Self.frameSeconds)
        let minimumFrames = Int(minimum / Self.frameSeconds)

        for slot in 0..<slots {
            var spans: [(Int, Int)] = []
            var start: Int?
            for frame in 0...frameCount {
                let value = frame < frameCount ? values[frame * slots + slot] : 0
                if let open = start {
                    if value < offset {
                        spans.append((open, frame))
                        start = nil
                    }
                } else if value > onset {
                    start = frame
                }
            }

            var bridged: [(Int, Int)] = []
            for span in spans {
                if let last = bridged.last, span.0 - last.1 <= bridgeFrames {
                    bridged[bridged.count - 1].1 = span.1
                } else {
                    bridged.append(span)
                }
            }

            for (low, high) in bridged where high - low >= minimumFrames {
                result.append(SpeakerAssignment.Turn(
                    speaker: String(slot),
                    start: Double(low) * Self.frameSeconds,
                    end: Double(high) * Self.frameSeconds
                ))
            }
        }
        return result.sorted { $0.start != $1.start ? $0.start < $1.start : $0.speaker < $1.speaker }
    }

    /// Voices in the order they first spoke for long enough to count, ignoring brief false starts.
    func arrivalOrder(minimum: Double = 0.4) -> [Int] {
        var seen: [Int] = []
        for turn in turns(minimum: minimum) {
            guard let slot = Int(turn.speaker), !seen.contains(slot) else { continue }
            seen.append(slot)
        }
        return seen
    }

    /// Seconds each voice spends clearly speaking.
    func speechSeconds(threshold: Float = 0.5) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for frame in 0..<frameCount {
            for slot in 0..<slots where values[frame * slots + slot] > threshold {
                result[slot, default: 0] += Self.frameSeconds
            }
        }
        return result
    }

    /// Stretches where only this voice is talking. These give clean voice prints.
    func soloStretches(
        slot: Int,
        minimum: Double = 1.0,
        longest: Double = 8,
        speaking: Float = 0.6,
        quiet: Float = 0.2
    ) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var start: Int?
        let maxFrames = Int(longest / Self.frameSeconds)

        func close(_ end: Int) {
            guard let open = start else { return }
            if Double(end - open) * Self.frameSeconds >= minimum {
                result.append(Double(open) * Self.frameSeconds...Double(end) * Self.frameSeconds)
            }
            start = nil
        }

        for frame in 0...frameCount {
            var solo = false
            if frame < frameCount, values[frame * slots + slot] > speaking {
                solo = (0..<slots).allSatisfy { $0 == slot || values[frame * slots + $0] < quiet }
            }
            if solo {
                if start == nil { start = frame }
                if let open = start, frame - open >= maxFrames { close(frame) }
            } else {
                close(frame)
            }
        }
        return result
    }

    /// Applies a merge plan: a voice mapped to another adds its likelihood to that voice, and a voice mapped
    /// to nil is removed, so its words go to whoever else was speaking or nearest.
    func merging(_ plan: [Int: Int?]) -> SpeakerActivity {
        guard !plan.isEmpty else { return self }
        var merged = values
        for frame in 0..<frameCount {
            let base = frame * slots
            for (from, target) in plan {
                let value = values[base + from]
                merged[base + from] = 0
                if let target {
                    merged[base + target] = min(1, merged[base + target] + value)
                }
            }
        }
        return SpeakerActivity(slots: slots, values: merged)
    }
}

/// Decides which voices are really the same person, from voice prints taken within this meeting only.
/// Nothing is kept afterwards, so nobody is recognised from one meeting to the next.
enum VoiceMerger {
    /// Two voice prints this alike are one person even when nobody said how many people there were.
    /// Deliberately strict: the speaker model rarely splits a voice, and joining two people is worse than not.
    static let sameVoice: Float = 0.72

    struct Voice {
        let slot: Int
        let seconds: Double
        /// L2-normalised voice print, or nil when the voice never spoke alone for long enough.
        let print: [Float]?
    }

    /// Which voices fold into which. When there are more voices than `expected`, the briefest voices that never
    /// spoke alone long enough for a print go first, since they are most likely noise. Then each voice joins the
    /// one it sounds most like, while the two are alike enough or there are still too many voices.
    static func plan(voices: [Voice], expected: Int?) -> [Int: Int?] {
        struct Group {
            var slot: Int
            var members: [Int]
            var seconds: Double
            var print: [Float]
        }

        var groups = voices.compactMap { voice -> Group? in
            guard let print = voice.print else { return nil }
            return Group(slot: voice.slot, members: [voice.slot], seconds: voice.seconds, print: print)
        }
        var unprinted = voices.filter { $0.print == nil }.sorted { $0.seconds < $1.seconds }
        var result: [Int: Int?] = [:]

        func count() -> Int { groups.count + unprinted.count }

        if let expected {
            while count() > expected, !unprinted.isEmpty, count() > 1 {
                result[unprinted.removeFirst().slot] = .some(nil)
            }
        }

        while groups.count > 1 {
            var best: (Int, Int, Float)?
            for i in groups.indices {
                for j in groups.indices where j > i {
                    let similarity = cosine(groups[i].print, groups[j].print)
                    if best == nil || similarity > best!.2 { best = (i, j, similarity) }
                }
            }
            guard let (i, j, similarity) = best else { break }
            let tooMany = expected.map { count() > $0 } ?? false
            guard similarity >= sameVoice || tooMany else { break }

            // The voice that spoke more keeps its number; the other folds into it.
            let (keep, drop) = groups[i].seconds >= groups[j].seconds ? (i, j) : (j, i)
            for member in groups[drop].members { result[member] = groups[keep].slot }
            let total = groups[keep].seconds + groups[drop].seconds
            let blended = zip(groups[keep].print, groups[drop].print).map {
                Float((Double($0) * groups[keep].seconds + Double($1) * groups[drop].seconds) / total)
            }
            groups[keep].members += groups[drop].members
            groups[keep].seconds = total
            groups[keep].print = normalized(blended)
            groups.remove(at: drop)
        }
        return result
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = max(vector.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        return vector.map { $0 / norm }
    }
}
