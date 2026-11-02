import AVFoundation
import FluidAudio
import Foundation
import os

actor SegmentCollector {
    private var segments: [TranscriptSegment] = []

    func add(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    func all() -> [TranscriptSegment] {
        segments.sorted { $0.start < $1.start }
    }
}

/// Transcribes saved audio files, for meetings recorded without a ready speech model or when you ask for a redo.
enum OfflineTranscriber {
    private static let log = Logger(subsystem: "com.rakan.Meetings", category: "transcription")

    static func run(
        meeting: Meeting,
        dataFolder: URL,
        asr: AsrManager,
        vad: VadManager,
        inPerson: Bool,
        stats: RecordingStats?,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> [TranscriptSegment] {
        let collector = SegmentCollector()
        let transcriber = LiveTranscriber(
            asr: asr,
            vad: vad,
            clock: { 0 },
            options: .forMeeting(inPerson: inPerson),
            stats: stats
        ) { segment in
            await collector.add(segment)
        }

        let tracks: [(AudioTrack, URL)] = [AudioTrack.mic, .system]
            .map { ($0, MeetingStore.audioURL($0, for: meeting, in: dataFolder)) }
            .filter { FileManager.default.fileExists(atPath: $0.1.path) }

        let totalSeconds = tracks.reduce(0.0) { sum, item in
            guard let file = try? AVAudioFile(forReading: item.1) else { return sum }
            return sum + Double(file.length) / file.processingFormat.sampleRate
        }
        var doneSeconds = 0.0

        for (track, url) in tracks {
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let resampler = StreamResampler()
                let chunkFrames: AVAudioFrameCount = AVAudioFrameCount(format.sampleRate)
                var framesRead: Int64 = 0

                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
                    try file.read(into: buffer, frameCount: chunkFrames)
                    if buffer.frameLength == 0 { break }

                    framesRead += Int64(buffer.frameLength)
                    let endTime = Double(framesRead) / format.sampleRate
                    transcriber.feed(track, samples: resampler.convert(buffer), endTime: endTime)
                    await transcriber.waitUntilQueued(below: 30)

                    if totalSeconds > 0 {
                        progress(min(1, (doneSeconds + endTime) / totalSeconds))
                    }
                }
                doneSeconds += Double(file.length) / format.sampleRate
            } catch {
                log.error("Reading \(url.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }

        await transcriber.finish()
        return await collector.all()
    }
}

/// The models for the careful in-person pass, loaded from disk for one recording.
struct RoomModels {
    let speakers: Nemotron3Models
    let prints: CampPlusModels?
}

/// Splits the other participants (and, for in-person meetings, the people in the room) into speakers
/// after the meeting, then labels each transcript line. Each track is separated on its own, because the
/// speaker models only tell voices apart within one recording.
///
/// In person this is the careful pass: Nemotron 3 looks at the whole recording ten seconds at a time, voices it
/// split in two are joined using voice prints taken from this meeting only, every word goes to the voice most
/// clearly speaking while it was said, and lines are cut where the voice changes. Speakers are then numbered in
/// the order they first speak, and names you typed follow the person.
enum SpeakerLabeler {
    private static let log = Logger(subsystem: "com.rakan.Meetings", category: "speakers")

    struct Outcome {
        var segments: [TranscriptSegment]
        var speakerNames: [String: String]
        var notes: [String]
        /// True when the careful pass produced the voices, rather than the live ones.
        var micDiarized = false
        var micVoices = 0
        var systemVoices = 0
        var splits = 0
        /// Voices the speaker model heard separately that turned out to be one person (or noise).
        var merged = 0
    }

    /// Who is speaking on the microphone, as the speaker model saw it.
    private enum RoomVoices {
        case activity(SpeakerActivity)
        case turns([SpeakerAssignment.Turn])

        var isEmpty: Bool {
            switch self {
            case .activity(let activity): activity.isEmpty
            case .turns(let turns): turns.isEmpty
            }
        }

        func voice(start: Double, end: Double, maxGap: Double) -> String? {
            switch self {
            case .activity(let activity):
                activity.voice(start: start, end: end, maxGap: maxGap).map(String.init)
            case .turns(let turns):
                SpeakerAssignment.speaker(start: start, end: end, turns: turns, maxGap: maxGap)
            }
        }
    }

    /// - Parameters:
    ///   - diarizeMic: Run the careful pass over the microphone. When false, only `liveActivity` is used.
    ///   - room: Nemotron 3 and the voice print model. Without them the older `micManager` is used, if given.
    ///   - liveActivity: The voices heard during the meeting. Used when the careful pass is skipped or fails.
    ///   - expected: How many people you said were in the room.
    ///   - pinned: Lines you moved by hand. They keep their speaker, renumbered along with everyone else.
    static func label(
        segments: [TranscriptSegment],
        speakerNames: [String: String] = [:],
        systemAudio: URL?,
        micAudio: URL?,
        systemManager: OfflineDiarizerManager?,
        room: RoomModels? = nil,
        micManager: OfflineDiarizerManager? = nil,
        diarizeMic: Bool = true,
        liveActivity: SpeakerActivity = SpeakerActivity(),
        expected: Int? = nil,
        pinned: Set<UUID> = [],
        inPerson: Bool,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Outcome {
        var notes: [String] = []
        var merged = 0

        let systemTurns = await diarizedTurns(
            for: .system,
            audio: systemAudio,
            manager: systemManager,
            normalize: false,
            notes: &notes,
            onProgress: onProgress
        )

        var mic = RoomVoices.turns([])
        var micDiarized = false
        if let micAudio, inPerson {
            if diarizeMic {
                if let room {
                    if let result = await carefulPass(micAudio, models: room, expected: expected, notes: &notes, onProgress: onProgress) {
                        mic = .activity(result.activity)
                        merged = result.merged
                    }
                } else if micManager != nil {
                    mic = .turns(await diarizedTurns(
                        for: .mic,
                        audio: micAudio,
                        manager: micManager,
                        normalize: true,
                        notes: &notes,
                        onProgress: onProgress
                    ))
                } else {
                    notes.append("The in-person speaker models aren't downloaded, so the room wasn't separated after the meeting.")
                }
                micDiarized = !mic.isEmpty
            }
            if mic.isEmpty, !liveActivity.isEmpty {
                mic = .activity(liveActivity)
                if diarizeMic, room != nil {
                    notes.append("The careful pass couldn't run, so the voices heard during the meeting were used.")
                }
            }
        }

        func voices(for track: AudioTrack) -> RoomVoices? {
            switch track {
            case .system: systemTurns.isEmpty ? nil : .turns(systemTurns)
            case .mic: inPerson && !mic.isEmpty ? mic : nil
            }
        }

        var splits = 0
        let expanded = segments.flatMap { segment -> [TranscriptSegment] in
            guard !pinned.contains(segment.id), let source = voices(for: segment.track) else { return [segment] }
            let pieces = SegmentSplitter.split(segment) { source.voice(start: $0.start, end: $0.end, maxGap: 0.5) }
            splits += pieces.count - 1
            return pieces
        }

        let ordered = expanded.sorted { $0.start < $1.start }
        var raw: [UUID: String] = [:]
        for segment in ordered where !pinned.contains(segment.id) {
            guard let source = voices(for: segment.track) else { continue }
            let reach: Double = segment.track == .mic ? 3 : 0
            if let voice = lineVoice(segment, source: source, maxGap: reach) {
                raw[segment.id] = "\(segment.track.rawValue):\(voice)"
            }
        }
        if inPerson {
            fillGaps(in: ordered, raw: &raw, pinned: pinned)
        }

        let numbers = SpeakerAssignment.numberByAppearance(raw, order: ordered.map(\.id))
        var fresh: [UUID: String] = [:]
        for (id, key) in raw {
            fresh[id] = numbers[key]
        }

        var previous: [UUID: String] = [:]
        var weights: [UUID: Double] = [:]
        for segment in ordered {
            weights[segment.id] = max(0.1, segment.end - segment.start)
            if let id = segment.speakerID, !pinned.contains(segment.id) { previous[segment.id] = id }
        }
        var renamed = SpeakerAssignment.relink(old: previous, new: fresh, weights: weights)

        // Lines moved by hand keep their speaker. One that no longer matches anyone becomes a new speaker.
        var next = numbers.count + 1
        for segment in ordered where pinned.contains(segment.id) {
            guard let old = segment.speakerID, renamed[old] == nil else { continue }
            renamed[old] = "S\(next)"
            next += 1
        }

        let labeled = expanded.map { segment -> TranscriptSegment in
            var copy = segment
            if pinned.contains(segment.id) {
                copy.speakerID = segment.speakerID.flatMap { renamed[$0] }
            } else if let id = fresh[segment.id] {
                copy.speakerID = id
            } else if voices(for: segment.track) != nil {
                copy.speakerID = nil
            }
            return copy
        }

        var names: [String: String] = [:]
        for (old, name) in speakerNames {
            if let new = renamed[old] { names[new] = name }
        }
        let used = Set(labeled.compactMap(\.speakerID))
        names = names.filter { used.contains($0.key) }

        func count(_ track: AudioTrack) -> Int {
            Set(labeled.filter { $0.track == track }.compactMap(\.speakerID)).count
        }

        return Outcome(
            segments: labeled,
            speakerNames: names,
            notes: notes,
            micDiarized: micDiarized,
            micVoices: count(.mic),
            systemVoices: count(.system),
            splits: splits,
            merged: merged
        )
    }

    /// The voice of a whole line: each word votes for who said it, weighted by how long it took to say.
    private static func lineVoice(_ segment: TranscriptSegment, source: RoomVoices, maxGap: Double) -> String? {
        if let words = segment.words, !words.isEmpty {
            var votes: [String: Double] = [:]
            for word in words {
                guard let voice = source.voice(start: word.start, end: word.end, maxGap: 0.5) else { continue }
                votes[voice, default: 0] += max(0.05, word.end - word.start)
            }
            if let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                return best.key
            }
        }
        return source.voice(start: segment.start, end: segment.end, maxGap: maxGap)
    }

    /// A room line the model couldn't place goes to whoever spoke nearest to it in time.
    private static func fillGaps(in ordered: [TranscriptSegment], raw: inout [UUID: String], pinned: Set<UUID>) {
        let mic = ordered.filter { $0.track == .mic && !pinned.contains($0.id) }
        let known = mic.filter { raw[$0.id] != nil }
        guard !known.isEmpty else { return }
        for segment in mic where raw[segment.id] == nil {
            let middle = (segment.start + segment.end) / 2
            let nearest = known.min { lhs, rhs in
                distance(middle, lhs) < distance(middle, rhs)
            }
            if let nearest { raw[segment.id] = raw[nearest.id] }
        }
    }

    private static func distance(_ time: Double, _ segment: TranscriptSegment) -> Double {
        max(0, segment.start - time, time - segment.end)
    }

    /// Nemotron 3 over the whole recording, then voices joined where voice prints say they're one person.
    static func carefulPass(
        _ audio: URL,
        models: RoomModels,
        expected: Int?,
        notes: inout [String],
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> (activity: SpeakerActivity, merged: Int)? {
        do {
            onProgress("Preparing the recording…")
            // Decoding, levelling and separating an hour of audio is heavy, so keep it off the main thread.
            // One steady gain for the whole recording keeps the difference between near and far voices.
            let speakers = models.speakers
            let (samples, activity) = try await Task.detached(priority: .userInitiated) {
                let samples = AudioNormalizer.normalized(try AudioFileSamples.read(audio))
                onProgress("Separating speakers…")
                let diarizer = Nemotron3Diarizer(config: SpeakerModels.careful, models: speakers)
                let output = try diarizer.processComplete(samples)
                let slots = SpeakerModels.careful.numSpeakers
                let values = Array(output.probabilities.prefix(output.frameCount * slots))
                return (samples, SpeakerActivity(slots: slots, values: values))
            }.value

            guard let prints = models.prints else { return (activity, 0) }
            onProgress("Checking voices…")
            let voices = await voicePrints(activity: activity, samples: samples, models: prints)
            let plan = VoiceMerger.plan(voices: voices, expected: expected)
            return (activity.merging(plan), plan.count)
        } catch {
            log.error("Speaker separation failed on the microphone: \(error.localizedDescription)")
            notes.append("Speaker separation failed on the microphone: \(error.localizedDescription)")
            return nil
        }
    }

    /// One voice print per voice, from up to 30 seconds where that voice speaks alone. Prints are compared
    /// within this meeting and then thrown away.
    private static func voicePrints(
        activity: SpeakerActivity,
        samples: [Float],
        models: CampPlusModels
    ) async -> [VoiceMerger.Voice] {
        let embedder = CampPlusEmbedder(models: models)
        let rate = 16_000.0
        var voices: [VoiceMerger.Voice] = []

        for (slot, seconds) in activity.speechSeconds().sorted(by: { $0.key < $1.key }) {
            let stretches = activity.soloStretches(slot: slot)
                .sorted { ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound) }
            var sum = [Float](repeating: 0, count: CampPlusEmbedder.embeddingDim)
            var used = 0.0
            for stretch in stretches where used < 30 {
                let low = max(0, Int(stretch.lowerBound * rate))
                let high = min(samples.count, Int(stretch.upperBound * rate))
                guard high - low >= Int(rate) else { continue }
                guard let print = try? await embedder.embed(audio: Array(samples[low..<high])) else { continue }
                let length = stretch.upperBound - stretch.lowerBound
                for index in sum.indices { sum[index] += print[index] * Float(length) }
                used += length
            }
            voices.append(VoiceMerger.Voice(slot: slot, seconds: seconds, print: used > 0 ? VoiceMerger.normalized(sum) : nil))
        }
        return voices
    }

    private static func diarizedTurns(
        for track: AudioTrack,
        audio: URL?,
        manager: OfflineDiarizerManager?,
        normalize: Bool,
        notes: inout [String],
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> [SpeakerAssignment.Turn] {
        guard let audio else { return [] }

        let name = track == .mic ? "microphone" : "system audio"
        guard let manager else {
            notes.append("The speaker model isn't set up, so the \(name) wasn't separated into speakers.")
            return []
        }

        let progress: @Sendable (Int, Int) -> Void = { done, total in
            guard total > 0 else { return }
            onProgress("Separating speakers… \(Int(Double(done) / Double(total) * 100))%")
        }

        do {
            if normalize {
                onProgress("Preparing the recording…")
                // Decoding and levelling an hour of audio is heavy, so keep it off the main thread.
                let samples = try await Task.detached(priority: .userInitiated) {
                    AudioNormalizer.normalized(try AudioFileSamples.read(audio))
                }.value
                let result = try await manager.process(audio: samples, progressCallback: progress)
                return result.segments.map {
                    SpeakerAssignment.Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
                }
            }

            let result = try await manager.process(audio, progressCallback: progress)
            return result.segments.map {
                SpeakerAssignment.Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            }
        } catch {
            log.error("Speaker separation failed on the \(name): \(error.localizedDescription)")
            notes.append("Speaker separation failed on the \(name): \(error.localizedDescription)")
            return []
        }
    }
}
