import Foundation
import os

struct TrackDiagnostics: Codable, Hashable {
    var seconds = 0.0
    var peakDecibels = -120.0
    var averageDecibels = -120.0
    var speechSeconds = 0.0
    var lines = 0
}

/// What the recording pipeline actually saw, saved next to each meeting so a silent failure can be explained.
struct MeetingDiagnostics: Codable, Hashable {
    var inPerson = false
    var mic: TrackDiagnostics?
    var system: TrackDiagnostics?
    var speakerEngine = ""
    var notes: [String] = []
    var generatedAt = Date.now
    /// Whether the careful pass over the whole recording produced the speakers. Optional so older files still load.
    var refined: Bool?
    var voices: Int?
    /// Why speaker separation didn't fully work, in plain words, or nil when it did.
    var speakerProblem: String?

    /// A plain-words reason nothing was transcribed, or nil when the audio looks healthy.
    var concern: String? {
        guard let mic else { return nil }
        let heard = mic.seconds + (system?.seconds ?? 0)
        guard heard >= 15 else { return nil }

        let lines = mic.lines + (system?.lines ?? 0)
        guard lines == 0 else { return nil }

        if mic.peakDecibels < -50 {
            return "Nothing was transcribed because the microphone was almost silent (loudest sound \(Int(mic.peakDecibels)) dB). Check that the right microphone is selected in Settings and that Meetings has microphone access."
        }
        if mic.speechSeconds == 0, (system?.speechSeconds ?? 0) == 0 {
            return "Nothing was transcribed because no speech was detected. The microphone picked up sound (loudest \(Int(mic.peakDecibels)) dB) but it never sounded like a voice. Try sitting closer to the Mac, or pick a different microphone in Settings."
        }
        return "Speech was detected but the speech model returned no text. Use ⋯ › Transcribe Recording to try again."
    }

    /// A warning for recordings that did produce text but were very quiet.
    var quietWarning: String? {
        guard inPerson, let mic, mic.seconds >= 30, mic.lines > 0, mic.averageDecibels < -52 else { return nil }
        return "The room was very quiet on the microphone (average \(Int(mic.averageDecibels)) dB). Voices far from the Mac may be missing."
    }

    var text: String {
        var lines = ["Mode: \(inPerson ? "In person" : "Online")"]
        if let mic { lines.append(Self.describe("Microphone", mic)) }
        if let system { lines.append(Self.describe("System audio", system)) }
        if !speakerEngine.isEmpty { lines.append("Speaker separation: \(speakerEngine)") }
        if let voices { lines.append("Voices found: \(voices)") }
        lines += notes
        if let concern { lines.append("Problem: \(concern)") }
        if let quietWarning { lines.append("Note: \(quietWarning)") }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ name: String, _ track: TrackDiagnostics) -> String {
        let seconds = Int(track.seconds.rounded())
        return "\(name): \(seconds) s recorded, loudest \(Int(track.peakDecibels)) dB, average \(Int(track.averageDecibels)) dB, "
            + "\(Int(track.speechSeconds.rounded())) s of speech detected, \(track.lines) lines transcribed"
    }
}

/// Collects levels and counts from the audio threads while a meeting is recorded or replayed.
final class RecordingStats: @unchecked Sendable {
    private struct Accumulator {
        var samples = 0
        var peak: Float = 0
        var sumSquares = 0.0
        var speech = 0.0
        var lines = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: [AudioTrack: Accumulator]())

    /// `samples` are 16 kHz mono.
    func record(_ track: AudioTrack, samples: [Float]) {
        guard !samples.isEmpty else { return }

        var peak: Float = 0
        var sum = 0.0
        for sample in samples {
            peak = max(peak, abs(sample))
            sum += Double(sample * sample)
        }

        state.withLock { values in
            var item = values[track, default: Accumulator()]
            item.samples += samples.count
            item.peak = max(item.peak, peak)
            item.sumSquares += sum
            values[track] = item
        }
    }

    func addSpeech(_ track: AudioTrack, seconds: Double) {
        state.withLock { $0[track, default: Accumulator()].speech += seconds }
    }

    func addLine(_ track: AudioTrack) {
        state.withLock { $0[track, default: Accumulator()].lines += 1 }
    }

    func snapshot(inPerson: Bool, speakerEngine: String, notes: [String] = []) -> MeetingDiagnostics {
        let values = state.withLock { $0 }

        func track(_ key: AudioTrack) -> TrackDiagnostics? {
            guard let item = values[key], item.samples > 0 else { return nil }
            let mean = (item.sumSquares / Double(item.samples)).squareRoot()
            return TrackDiagnostics(
                seconds: Double(item.samples) / 16_000,
                peakDecibels: Self.decibels(Double(item.peak)),
                averageDecibels: Self.decibels(mean),
                speechSeconds: item.speech,
                lines: item.lines
            )
        }

        return MeetingDiagnostics(
            inPerson: inPerson,
            mic: track(.mic),
            system: track(.system),
            speakerEngine: speakerEngine,
            notes: notes
        )
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 1e-6))
    }
}
