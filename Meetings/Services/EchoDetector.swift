import Accelerate
import AVFoundation
import Foundation
import os

/// Tells whether a microphone line is really the call playing through the Mac's speakers.
///
/// It compares how loud the microphone and the call were, moment to moment. When the speakers leak into the
/// microphone, the microphone's loudness rises and falls with the call a fraction of a second later. When you speak,
/// it follows your own voice instead. This works whatever the words are, so it catches short and misheard lines
/// that a word-by-word comparison misses.
enum EchoDetector {
    static let sampleRate = 16_000.0
    static let frameSeconds = 0.02
    static let samplesPerFrame = 320
    /// Quieter than this counts as silence.
    static let floor: Float = -70
    /// The call counts as playing when it is at least this loud.
    static let activeLevel: Float = -50
    /// How closely the microphone has to follow the call for a line to count as the call.
    static let threshold: Float = 0.55
    /// How far apart the two tracks can be. They start at slightly different moments, and speakers add a delay.
    static let lagRange: ClosedRange<Double> = -3...3
    /// How far each line may differ from the meeting's overall delay.
    static let lineSlack = 0.12
    /// Lines shorter than this are too short to judge by sound.
    static let minimumSeconds = 0.4
    /// How far above its quietest moment the microphone must rise to count as hearing something, in dB.
    static let micSpeechRise: Float = 12
    /// How much louder than the call's echo the microphone can be before it must be someone in the room, in dB.
    static let louderThanEcho: Float = 10
    /// The share of the microphone's sound the call may leave unexplained. Above this, someone in the room spoke.
    static let unexplainedLimit: Float = 0.15

    // MARK: - Loudness

    /// The loudness of each 20 ms frame, in dB. `samples` must be 16 kHz mono.
    static func envelope(_ samples: [Float]) -> [Float] {
        let count = samples.count / samplesPerFrame
        guard count > 0 else { return [] }

        var result = [Float](repeating: floor, count: count)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in 0..<count {
                var meanSquare: Float = 0
                vDSP_measqv(base + index * samplesPerFrame, 1, &meanSquare, vDSP_Length(samplesPerFrame))
                result[index] = decibels(meanSquare)
            }
        }
        return result
    }

    /// The loudness of a whole recording, read a second at a time so long meetings never sit in memory.
    static func envelope(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let resampler = StreamResampler()
        let chunkFrames = AVAudioFrameCount(format.sampleRate)

        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) / format.sampleRate / frameSeconds) + 1)
        var pending: [Float] = []

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            try file.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }

            pending += resampler.convert(buffer)
            let usable = pending.count / samplesPerFrame * samplesPerFrame
            guard usable > 0 else { continue }
            result += envelope(Array(pending[..<usable]))
            pending.removeFirst(usable)
        }
        return result
    }

    static func decibels(_ meanSquare: Float) -> Float {
        max(floor, 10 * log10(max(meanSquare, 1e-12)))
    }

    // MARK: - Comparing the tracks

    /// How many frames later the microphone hears the call, worked out over the whole stretch both tracks share.
    /// Positive means the microphone is behind. Nil when the call was silent.
    static func lag(mic: [Float], system: [Float], range: ClosedRange<Double> = lagRange) -> Int? {
        let count = min(mic.count, system.count)
        let low = Int((range.lowerBound / frameSeconds).rounded())
        let high = Int((range.upperBound / frameSeconds).rounded())
        guard count > (high - low) * 2 else { return nil }
        guard system[..<count].contains(where: { $0 >= activeLevel }) else { return nil }

        let a = standardized(Array(mic[..<count]))
        let b = standardized(Array(system[..<count]))

        var best: (lag: Int, score: Float)?
        a.withUnsafeBufferPointer { micPointer in
            b.withUnsafeBufferPointer { systemPointer in
                guard let micBase = micPointer.baseAddress, let systemBase = systemPointer.baseAddress else { return }
                for lag in low...high {
                    // mic[i] lines up with system[i - lag].
                    let micStart = max(0, lag)
                    let systemStart = max(0, -lag)
                    let length = count - abs(lag)
                    guard length > 0 else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(micBase + micStart, 1, systemBase + systemStart, 1, &dot, vDSP_Length(length))
                    let score = dot / Float(length)
                    if best == nil || score > best!.score { best = (lag, score) }
                }
            }
        }
        return best?.lag
    }

    /// How closely the microphone followed the call during one line, from -1 to 1. Nil when there isn't enough to
    /// judge or the call was quiet then, which means the line can't be the call.
    static func similarity(start: Double, end: Double, mic: [Float], system: [Float], lag: Int) -> Float? {
        guard end - start >= minimumSeconds else { return nil }
        let first = max(0, Int((start / frameSeconds).rounded(.down)))
        let last = min(mic.count, Int((end / frameSeconds).rounded(.up)))
        guard last - first >= Int(minimumSeconds / frameSeconds) else { return nil }

        let said = Array(mic[first..<last])
        // Whether someone in the room spoke is a property of the line, so judge it once at the meeting's delay. The
        // check already allows for the line's slack.
        let from = first - lag
        guard from >= 0, last - lag <= system.count,
              unexplainedSound(mic: said, heard: Array(system[from..<(last - lag)]), system: system, from: from)
                <= unexplainedLimit
        else { return nil }

        let slack = Int((lineSlack / frameSeconds).rounded())
        var best: Float?
        for shift in (lag - slack)...(lag + slack) {
            let from = first - shift
            let to = last - shift
            guard from >= 0, to <= system.count else { continue }

            let heard = Array(system[from..<to])
            let active = heard.filter { $0 >= activeLevel }.count
            guard Float(active) / Float(heard.count) >= 0.3 else { continue }

            if let score = pearson(said, heard), best == nil || score > best! {
                best = score
            }
        }
        return best
    }

    /// How much of the microphone's sound the call can't explain, from 0 to 1. Sound comes from the speakers at a
    /// steady level below the call, and only while the call is making sound. Frames well above that level, or with the
    /// call quiet, mean someone in the room spoke, even if the call can be heard underneath.
    /// `heard` is the call lined up with `mic`; `from` is where it starts in `system`.
    static func unexplainedSound(mic: [Float], heard: [Float], system: [Float], from: Int) -> Float {
        guard let quietest = mic.min() else { return 0 }

        // How much quieter the microphone hears the call. The low end, so moments you speak over it don't count.
        let differences = zip(mic, heard).filter { $0.1 >= activeLevel }.map { $0.0 - $0.1 }.sorted()
        guard !differences.isEmpty else { return 1 }
        let pickup = differences[Int(Float(differences.count - 1) * 0.2)]

        let reach = Int((lineSlack / frameSeconds).rounded())
        var loud = 0
        var unexplained = 0
        for (index, level) in mic.enumerated() where level >= quietest + micSpeechRise {
            loud += 1
            let centre = from + index
            let window = system[max(0, centre - reach)..<min(system.count, centre + reach + 1)]
            guard let call = window.max(), call >= activeLevel, level <= call + pickup + louderThanEcho else {
                unexplained += 1
                continue
            }
        }
        return loud == 0 ? 0 : Float(unexplained) / Float(loud)
    }

    static func isEcho(start: Double, end: Double, mic: [Float], system: [Float], lag: Int) -> Bool {
        guard let score = similarity(start: start, end: end, mic: mic, system: system, lag: lag) else { return false }
        return score >= threshold
    }

    /// Which microphone lines were the call, judged from the saved recordings. Lines you moved yourself are kept.
    static func echoes(
        in segments: [TranscriptSegment],
        micAudio: URL,
        systemAudio: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Set<UUID> {
        try await Task.detached(priority: .userInitiated) {
            progress(0)
            let mic = try envelope(of: micAudio)
            progress(0.45)
            let system = try envelope(of: systemAudio)
            progress(0.9)
            guard let lag = lag(mic: mic, system: system) else {
                progress(1)
                return []
            }

            var found = Set<UUID>()
            for segment in segments where segment.track == .mic && segment.pinned != true {
                if isEcho(start: segment.start, end: segment.end, mic: mic, system: system, lag: lag) {
                    found.insert(segment.id)
                }
            }
            progress(1)
            return found
        }.value
    }

    // MARK: - Maths

    private static func standardized(_ values: [Float]) -> [Float] {
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(values, 1, nil, 1, &mean, &deviation, vDSP_Length(values.count))
        guard deviation > 1e-6 else { return [Float](repeating: 0, count: values.count) }
        var result = [Float](repeating: 0, count: values.count)
        vDSP_normalize(values, 1, &result, 1, &mean, &deviation, vDSP_Length(values.count))
        return result
    }

    static func pearson(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, a.count > 2 else { return nil }
        let x = standardized(a)
        let y = standardized(b)
        guard x.contains(where: { $0 != 0 }), y.contains(where: { $0 != 0 }) else { return nil }
        var dot: Float = 0
        vDSP_dotpr(x, 1, y, 1, &dot, vDSP_Length(x.count))
        return dot / Float(x.count)
    }
}

/// Keeps the loudness of both tracks while a meeting records, so each new microphone line can be checked against
/// the call as it arrives. Safe to feed from the audio threads.
final class EchoMonitor: @unchecked Sendable {
    private struct Track {
        var frames: [Float] = []
        var pending: [Float] = []
    }

    private struct State {
        var tracks: [AudioTrack: Track] = [:]
        var lag: Int?
        var lagCheckedAt = -Double.infinity
    }

    /// The overall delay is worked out from the most recent stretch, and checked again every so often.
    private static let lagWindow = 180.0
    private static let lagInterval = 15.0

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `samples` are 16 kHz mono and end at `endTime` on the recording clock, the same clock the lines use.
    func feed(_ track: AudioTrack, samples: [Float], endTime: TimeInterval) {
        guard !samples.isEmpty else { return }
        let size = EchoDetector.samplesPerFrame

        state.withLock { state in
            var value = state.tracks[track, default: Track()]
            value.pending += samples
            let usable = value.pending.count / size * size
            guard usable > 0 else {
                state.tracks[track] = value
                return
            }

            let frames = EchoDetector.envelope(Array(value.pending[..<usable]))
            value.pending.removeFirst(usable)

            let leftover = Double(value.pending.count) / EchoDetector.sampleRate
            let end = Int(((endTime - leftover) / EchoDetector.frameSeconds).rounded())
            let first = max(0, end - frames.count)
            if value.frames.count < first {
                value.frames += [Float](repeating: EchoDetector.floor, count: first - value.frames.count)
            }
            for (offset, level) in frames.enumerated() {
                let index = first + offset
                if index < value.frames.count {
                    value.frames[index] = level
                } else {
                    value.frames.append(level)
                }
            }
            state.tracks[track] = value
        }
    }

    /// Whether a microphone line from `start` to `end` seconds sounds like the call.
    func isEcho(start: TimeInterval, end: TimeInterval) -> Bool {
        state.withLock { state in
            guard let mic = state.tracks[.mic]?.frames, let system = state.tracks[.system]?.frames else { return false }

            if end - state.lagCheckedAt >= Self.lagInterval || state.lag == nil {
                let count = min(mic.count, system.count)
                let window = Int(Self.lagWindow / EchoDetector.frameSeconds)
                let from = max(0, count - window)
                if let lag = EchoDetector.lag(
                    mic: Array(mic[from..<count]),
                    system: Array(system[from..<count]),
                    range: -1...2
                ) {
                    state.lag = lag
                    state.lagCheckedAt = end
                }
            }
            guard let lag = state.lag else { return false }
            return EchoDetector.isEcho(start: start, end: end, mic: mic, system: system, lag: lag)
        }
    }
}
