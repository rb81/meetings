import FluidAudio
import Foundation
import os

/// Pure rules for deciding who said a line. Kept free of audio and UI so they can be tested on their own.
enum SpeakerAssignment {
    struct Turn: Hashable, Sendable {
        let speaker: String
        let start: Double
        let end: Double
    }

    /// The voice that speaks longest during `start...end`. When nobody overlaps the line, the nearest voice
    /// within `maxGap` seconds takes it, because the models tend to miss the quiet edges of speech.
    static func speaker(start: Double, end: Double, turns: [Turn], maxGap: Double = 3) -> String? {
        var overlap: [String: Double] = [:]
        for turn in turns {
            let shared = min(end, turn.end) - max(start, turn.start)
            if shared > 0 {
                overlap[turn.speaker, default: 0] += shared
            }
        }

        let best = overlap.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        if let first = best.first { return first.key }

        let middle = (start + end) / 2
        guard let nearest = turns.min(by: { gap(from: middle, to: $0) < gap(from: middle, to: $1) }),
              gap(from: middle, to: nearest) <= maxGap
        else { return nil }
        return nearest.speaker
    }

    /// Numbers voices S1, S2, … in the order their first line appears, so whoever speaks first is always
    /// Speaker 1. `voices` holds each line's voice; `order` is the lines in time order.
    static func numberByAppearance(_ voices: [UUID: String], order: [UUID]) -> [String: String] {
        var result: [String: String] = [:]
        for id in order {
            guard let voice = voices[id], result[voice] == nil else { continue }
            result[voice] = "S\(result.count + 1)"
        }
        return result
    }

    private struct Pair: Hashable {
        let old: String
        let new: String
    }

    /// After the speakers are numbered afresh, works out which old ID became which new one, so names and
    /// lines you moved by hand follow the person. Each old ID goes to the new ID it shares the most speech
    /// with, one to one. `weights` are line lengths in seconds.
    static func relink(old: [UUID: String], new: [UUID: String], weights: [UUID: Double]) -> [String: String] {
        var shared: [Pair: Double] = [:]
        for (id, before) in old {
            guard let after = new[id] else { continue }
            shared[Pair(old: before, new: after), default: 0] += weights[id] ?? 1
        }

        let ranked = shared.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return (lhs.key.old, lhs.key.new) < (rhs.key.old, rhs.key.new)
        }

        var result: [String: String] = [:]
        var claimed = Set<String>()
        for (pair, _) in ranked where result[pair.old] == nil && !claimed.contains(pair.new) {
            result[pair.old] = pair.new
            claimed.insert(pair.new)
        }
        return result
    }

    private static func gap(from time: Double, to turn: Turn) -> Double {
        max(0, turn.start - time, time - turn.end)
    }
}

/// Separates the voices in the room while the meeting is still going, with NVIDIA's streaming Nemotron 3
/// diarizer (up to eight speakers, about three seconds behind). Audio goes in as it is recorded. What it has
/// heard so far can be read at any time.
final class LiveSpeakerTracker: @unchecked Sendable {
    private let heard = OSAllocatedUnfairLock(initialState: SpeakerActivity())
    private let continuation: AsyncStream<[Float]>.Continuation
    private let onUpdate: @Sendable () -> Void
    private let log = Logger(subsystem: "com.rakan.Meetings", category: "speakers")
    private var task: Task<Void, Never>?

    init(models: Nemotron3Models, onUpdate: @escaping @Sendable () -> Void) {
        // The diarizer isn't thread-safe, so it lives entirely inside the one task below.
        let diarizer = Nemotron3Diarizer(config: SpeakerModels.live, models: models)

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        self.onUpdate = onUpdate

        task = Task.detached(priority: .userInitiated) { [self] in
            await run(diarizer, stream)
        }
    }

    /// 16 kHz mono samples, exactly as recorded and without gaps. Not boosted: the model compares how voices
    /// sound, and a gain that follows the level would make near and far voices sound more alike.
    func feed(_ samples: [Float]) {
        continuation.yield(samples)
    }

    /// Stops taking audio and settles the last few seconds.
    func finish() async {
        continuation.finish()
        await task?.value
    }

    /// Everything heard so far, every 10 ms.
    func activity() -> SpeakerActivity {
        heard.withLock { $0 }
    }

    /// The model's own number for the voice that said a line, or nil when no voice has been heard near it yet.
    /// These numbers aren't shown: the model can hand out a number to a cough or a chair before anyone speaks,
    /// so lines are numbered by `SpeakerAssignment.numberByAppearance` instead.
    func voice(start: Double, end: Double) -> Int? {
        heard.withLock { $0 }.voice(start: start, end: end, maxGap: 1.5)
    }

    private func run(_ diarizer: Nemotron3Diarizer, _ stream: AsyncStream<[Float]>) async {
        for await samples in stream {
            do {
                diarizer.appendAudio(samples)
                let results = try diarizer.processBufferedAudio()
                if !results.isEmpty { publish(results) }
            } catch {
                log.error("Live speaker separation failed: \(error.localizedDescription)")
            }
        }

        do {
            publish(try diarizer.finishStream())
        } catch {
            log.error("Finishing live speaker separation failed: \(error.localizedDescription)")
        }
    }

    private func publish(_ results: [Nemotron3ChunkResult]) {
        heard.withLock { activity in
            for result in results {
                activity.append(Array(result.probabilities.prefix(result.frameCount * activity.slots)))
            }
        }
        onUpdate()
    }
}
