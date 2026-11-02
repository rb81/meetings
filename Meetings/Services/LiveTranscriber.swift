import FluidAudio
import Foundation
import os

/// Transcribes the microphone and system-audio tracks as they are recorded (or replayed from files).
///
/// Each track is cut into utterances at speech pauses (Silero VAD) and every utterance
/// is transcribed by Parakeet as soon as it ends, so text trails speech by a couple of seconds.
final class LiveTranscriber: @unchecked Sendable {
    typealias SegmentHandler = @Sendable (TranscriptSegment) async -> Void

    private struct Chunk: Sendable {
        let samples: [Float]
        let arrivedAt: TimeInterval
    }

    struct Options: Sendable {
        /// Voice-detection sensitivity. Lower hears quieter speech, which in-person rooms need.
        var speechThreshold: Float = 0.5
        /// Tracks whose quiet audio is lifted before it is analysed.
        var autoGain: Set<AudioTrack> = []

        /// In a room nobody is close to the microphone, so listen harder and lift the level.
        static func forMeeting(inPerson: Bool) -> Options {
            inPerson ? Options(speechThreshold: 0.35, autoGain: [.mic]) : Options()
        }
    }

    private static let sampleRate = 16_000.0
    private static let chunkSize = 4_096
    private static let chunkDuration = Double(chunkSize) / sampleRate
    private static let minSpeechChunks = 2
    private static let hangover: TimeInterval = 0.7
    private static let softLimit: TimeInterval = 8
    private static let softPause: TimeInterval = 0.25
    private static let hardLimit: TimeInterval = 14

    private let asr: AsrManager
    private let vad: VadManager
    private let clock: @Sendable () -> TimeInterval
    private let options: Options
    private let stats: RecordingStats?
    private let speakers: LiveSpeakerTracker?
    private let gains: [AudioTrack: AutoGain]
    private let onSegment: SegmentHandler
    private let queued = OSAllocatedUnfairLock(initialState: 0)
    private let log = Logger(subsystem: "com.rakan.Meetings", category: "transcription")

    private var continuations: [AudioTrack: AsyncStream<Chunk>.Continuation] = [:]
    private var tasks: [Task<Void, Never>] = []

    /// `clock` reports seconds of recorded time, so time spent paused doesn't count. `speakers` receives the
    /// microphone audio so voices can be told apart while the meeting runs.
    init(
        asr: AsrManager,
        vad: VadManager,
        clock: @escaping @Sendable () -> TimeInterval,
        options: Options = Options(),
        stats: RecordingStats? = nil,
        speakers: LiveSpeakerTracker? = nil,
        onSegment: @escaping SegmentHandler
    ) {
        self.asr = asr
        self.vad = vad
        self.clock = clock
        self.options = options
        self.stats = stats
        self.speakers = speakers
        self.onSegment = onSegment
        self.gains = Dictionary(uniqueKeysWithValues: options.autoGain.map { ($0, AutoGain()) })

        for track in [AudioTrack.mic, .system] {
            let (stream, continuation) = AsyncStream.makeStream(of: Chunk.self)
            continuations[track] = continuation
            tasks.append(Task { [self] in await process(track: track, stream: stream) })
        }
    }

    /// Live capture. Safe to call from audio threads. `samples` must be 16 kHz mono.
    func feed(_ track: AudioTrack, samples: [Float]) {
        feed(track, samples: samples, endTime: clock())
    }

    /// Replay from a file. `endTime` is the time, in seconds from the start, at which `samples` end.
    func feed(_ track: AudioTrack, samples: [Float], endTime: TimeInterval) {
        guard !samples.isEmpty else { return }
        stats?.record(track, samples: samples)

        // The speaker model gets the audio as recorded. Boosting is for the speech model only.
        if track == .mic {
            speakers?.feed(samples)
        }
        let boosted = gains[track]?.apply(samples) ?? samples

        queued.withLock { $0 += boosted.count }
        continuations[track]?.yield(Chunk(samples: boosted, arrivedAt: endTime))
    }

    /// Sends a second of silence down both tracks so a sentence that was cut off by a pause is finished and shown.
    func padSilence() {
        let silence = [Float](repeating: 0, count: Int(Self.sampleRate))
        let now = clock()
        for track in [AudioTrack.mic, .system] {
            queued.withLock { $0 += silence.count }
            continuations[track]?.yield(Chunk(samples: silence, arrivedAt: now))
        }
    }

    /// Lets replay wait until the transcriber has caught up, so memory stays small.
    func waitUntilQueued(below seconds: Double) async {
        let limit = Int(seconds * Self.sampleRate)
        while queued.withLock({ $0 }) > limit {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Stops accepting audio, then waits until everything already received is transcribed.
    func finish() async {
        for continuation in continuations.values {
            continuation.finish()
        }
        for task in tasks {
            await task.value
        }
    }

    private func process(track: AudioTrack, stream: AsyncStream<Chunk>) async {
        var vadState = await vad.makeStreamState()
        var pending: [Float] = []
        var preroll: [Float] = []
        var utterance: [Float] = []
        var utteranceStart: TimeInterval = 0
        var speechChunks = 0
        var silence: TimeInterval = 0
        var inSpeech = false

        func flush() async {
            let samples = utterance
            let start = utteranceStart
            let enoughSpeech = speechChunks >= Self.minSpeechChunks

            utterance.removeAll(keepingCapacity: true)
            preroll = []
            inSpeech = false
            speechChunks = 0
            silence = 0

            if enoughSpeech {
                stats?.addSpeech(track, seconds: Double(samples.count) / Self.sampleRate)
                await emit(track: track, samples: samples, start: start)
            }
        }

        for await chunk in stream {
            queued.withLock { $0 -= chunk.samples.count }
            pending.append(contentsOf: chunk.samples)

            while pending.count >= Self.chunkSize {
                let samples = Array(pending.prefix(Self.chunkSize))
                pending.removeFirst(Self.chunkSize)

                let chunkEnd = chunk.arrivedAt - Double(pending.count) / Self.sampleRate
                let chunkStart = chunkEnd - Self.chunkDuration

                let result: VadStreamResult
                do {
                    result = try await vad.processStreamingChunk(samples, state: vadState)
                } catch {
                    log.error("VAD failed: \(error.localizedDescription)")
                    continue
                }
                vadState = result.state

                if result.probability >= options.speechThreshold {
                    if !inSpeech {
                        inSpeech = true
                        utterance = preroll
                        utteranceStart = max(0, chunkStart - (preroll.isEmpty ? 0 : Self.chunkDuration))
                        preroll = []
                    }
                    utterance.append(contentsOf: samples)
                    speechChunks += 1
                    silence = 0
                } else if inSpeech {
                    utterance.append(contentsOf: samples)
                    silence += Self.chunkDuration
                    let length = Double(utterance.count) / Self.sampleRate
                    if silence >= Self.hangover || (length >= Self.softLimit && silence >= Self.softPause) {
                        await flush()
                    }
                } else {
                    preroll = samples
                }

                if inSpeech, Double(utterance.count) / Self.sampleRate >= Self.hardLimit {
                    await flush()
                }
            }
        }

        if inSpeech {
            utterance.append(contentsOf: pending)
            await flush()
        }
    }

    private func emit(track: AudioTrack, samples: [Float], start: TimeInterval) async {
        var input = samples
        let minimum = Int(Self.sampleRate)
        if input.count < minimum {
            input.append(contentsOf: [Float](repeating: 0, count: minimum - input.count))
        }

        do {
            let layers = await asr.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: layers)
            let result = try await asr.transcribe(input, decoderState: &decoderState)

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            let words = result.tokenTimings.map(buildWordTimings(from:))?.map {
                SegmentWord(text: $0.word, start: start + $0.startTime, end: start + $0.endTime)
            }

            let segment = TranscriptSegment(
                track: track,
                start: start,
                end: start + Double(samples.count) / Self.sampleRate,
                text: text,
                words: words
            )
            stats?.addLine(track)
            await onSegment(segment)
        } catch {
            log.error("Transcription failed: \(error.localizedDescription)")
        }
    }
}
