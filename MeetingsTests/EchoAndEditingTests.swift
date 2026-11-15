import XCTest

@testable import Meetings

/// Repeatable random numbers, so the synthetic audio is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Noise switched on and off in syllable-sized bursts, which is close enough to speech for loudness envelopes.
private func speechLike(seconds: Double, seed: UInt64, level: Float = 0.3) -> [Float] {
    var random = SeededGenerator(state: seed)
    let count = Int(seconds * EchoDetector.sampleRate)
    var samples = [Float](repeating: 0, count: count)
    var index = 0
    while index < count {
        let length = Int(Double.random(in: 0.08...0.35, using: &random) * EchoDetector.sampleRate)
        let talking = Double.random(in: 0...1, using: &random) < 0.65
        let loudness = talking ? level * Float.random(in: 0.3...1, using: &random) : 0
        for sample in index..<min(count, index + length) {
            samples[sample] = loudness * Float.random(in: -1...1, using: &random)
        }
        index += length
    }
    return samples
}

/// What a microphone hears from the speakers: the call, later and quieter, over a little room noise.
private func speakerBleed(_ call: [Float], delay: Double, gain: Float, seed: UInt64) -> [Float] {
    var random = SeededGenerator(state: seed)
    let offset = Int(delay * EchoDetector.sampleRate)
    return (0..<call.count).map { index in
        let heard = index >= offset ? call[index - offset] * gain : 0
        return heard + 0.002 * Float.random(in: -1...1, using: &random)
    }
}

final class EchoDetectorTests: XCTestCase {
    private let call = speechLike(seconds: 60, seed: 1)

    func testFindsHowLateTheMicrophoneHearsTheCall() throws {
        let mic = EchoDetector.envelope(speakerBleed(call, delay: 0.3, gain: 0.2, seed: 2))
        let system = EchoDetector.envelope(call)

        let lag = try XCTUnwrap(EchoDetector.lag(mic: mic, system: system))
        XCTAssertEqual(Double(lag) * EchoDetector.frameSeconds, 0.3, accuracy: 0.04)
    }

    func testCallThroughTheSpeakersIsAnEcho() throws {
        let mic = EchoDetector.envelope(speakerBleed(call, delay: 0.3, gain: 0.2, seed: 2))
        let system = EchoDetector.envelope(call)
        let lag = try XCTUnwrap(EchoDetector.lag(mic: mic, system: system))

        XCTAssertTrue(EchoDetector.isEcho(start: 10, end: 14, mic: mic, system: system, lag: lag))
    }

    func testYourOwnVoiceIsNotAnEcho() {
        let mic = EchoDetector.envelope(speechLike(seconds: 60, seed: 3))
        let system = EchoDetector.envelope(call)

        XCTAssertFalse(EchoDetector.isEcho(start: 10, end: 14, mic: mic, system: system, lag: 15))
    }

    func testTalkingOverTheCallIsNotAnEcho() throws {
        let bleed = speakerBleed(call, delay: 0.3, gain: 0.2, seed: 2)
        let mic = EchoDetector.envelope(bleed)
        let system = EchoDetector.envelope(call)
        let lag = try XCTUnwrap(EchoDetector.lag(mic: mic, system: system))

        // You speak up loudly from 20 to 30 seconds while the call carries on.
        let you = speechLike(seconds: 60, seed: 4, level: 0.6)
        var mixed = bleed
        let from = Int(20 * EchoDetector.sampleRate), to = Int(30 * EchoDetector.sampleRate)
        for index in from..<to { mixed[index] += you[index] }

        XCTAssertFalse(EchoDetector.isEcho(start: 22, end: 26, mic: EchoDetector.envelope(mixed), system: system, lag: lag))
    }

    func testNothingIsAnEchoWhenTheCallIsSilent() {
        let silence = [Float](repeating: 0, count: call.count)
        let mic = EchoDetector.envelope(speechLike(seconds: 60, seed: 5))
        let system = EchoDetector.envelope(silence)

        XCTAssertNil(EchoDetector.lag(mic: mic, system: system))
        XCTAssertFalse(EchoDetector.isEcho(start: 10, end: 14, mic: mic, system: system, lag: 0))
    }

    func testVeryShortLinesAreNotJudged() {
        let mic = EchoDetector.envelope(speakerBleed(call, delay: 0, gain: 0.2, seed: 2))
        let system = EchoDetector.envelope(call)

        XCTAssertNil(EchoDetector.similarity(start: 10, end: 10.2, mic: mic, system: system, lag: 0))
    }
}

final class EchoFilterTests: XCTestCase {
    private func line(_ track: AudioTrack, _ text: String, _ start: Double, _ end: Double, pinned: Bool = false) -> TranscriptSegment {
        var segment = TranscriptSegment(track: track, start: start, end: end, text: text)
        if pinned { segment.pinned = true }
        return segment
    }

    func testLongLineSpanningTwoCallLinesIsAnEcho() {
        let call = [
            line(.system, "So the budget for next quarter", 10, 12),
            line(.system, "is going to be a little tighter than planned", 12, 15),
        ]
        let mic = line(.mic, "so the budget for next quarter is going to be a little tighter", 10.5, 15.5)

        XCTAssertTrue(EchoFilter.isEcho(mic, among: call + [mic]))
    }

    func testShortLineMustMatchOneCallLine() {
        let call = [line(.system, "Thanks everyone for joining", 10, 12), line(.system, "today we have", 12, 13)]
        let echo = line(.mic, "thanks for joining", 10.2, 12.2)
        let reply = line(.mic, "thanks we have", 12, 13)

        XCTAssertTrue(EchoFilter.isEcho(echo, among: call))
        XCTAssertFalse(EchoFilter.isEcho(reply, among: call))
    }

    func testYourOwnWordsAndMovedLinesStay() {
        let call = [line(.system, "Does anyone have a question about the roadmap", 10, 13)]
        let question = line(.mic, "Yes I wanted to ask about hiring plans for next year", 14, 17)
        let moved = line(.mic, "does anyone have a question about the roadmap", 10, 13, pinned: true)

        let result = EchoFilter.removingEchoes(from: call + [question, moved])
        XCTAssertEqual(result.removed, 0)
    }

    func testLinesFarFromTheCallStay() {
        let call = [line(.system, "We will ship the release on Friday", 10, 12)]
        let later = line(.mic, "we will ship the release on Friday", 40, 42)

        XCTAssertFalse(EchoFilter.isEcho(later, among: call))
    }
}

final class StatusTextTests: XCTestCase {
    func testSplitsOffTheProgress() {
        let parsed = StatusText.parse("Transcribing the recording… 42%")
        XCTAssertEqual(parsed.text, "Transcribing the recording…")
        XCTAssertEqual(try XCTUnwrap(parsed.progress), 0.42, accuracy: 0.0001)
    }

    func testLeavesOtherStatusesAlone() {
        let parsed = StatusText.parse("Separating speakers…")
        XCTAssertEqual(parsed.text, "Separating speakers…")
        XCTAssertNil(parsed.progress)
    }
}

final class CallVoiceMergingTests: XCTestCase {
    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerAssignment.Turn {
        SpeakerAssignment.Turn(speaker: speaker, start: start, end: end)
    }

    func testOneVoiceSplitInTwoIsJoined() {
        let turns = [turn("S1", 0, 60), turn("S2", 60, 70), turn("S1", 70, 200)]
        let prints = ["S1": [1, 0.1, 0], "S2": [0.95, 0.15, 0.05]] as [String: [Float]]

        let result = SpeakerLabeler.joiningSimilarVoices(turns, prints: prints, expected: nil)
        XCTAssertEqual(result.merged, 1)
        XCTAssertEqual(Set(result.turns.map(\.speaker)), ["S1"])
    }

    func testDifferentVoicesStayApartUnlessYouSaySo() {
        let turns = [turn("S1", 0, 60), turn("S2", 60, 70), turn("S1", 70, 200)]
        let prints = ["S1": [1, 0, 0], "S2": [0, 1, 0]] as [String: [Float]]

        XCTAssertEqual(SpeakerLabeler.joiningSimilarVoices(turns, prints: prints, expected: nil).merged, 0)

        let told = SpeakerLabeler.joiningSimilarVoices(turns, prints: prints, expected: 1)
        XCTAssertEqual(Set(told.turns.map(\.speaker)), ["S1"])
    }
}

final class CacheJanitorTests: XCTestCase {
    func testReadsTheProcessFromHalfFinishedCopies() {
        XCTAssertEqual(CacheJanitor.writerProcess(of: "a1b2.tmp.2246_0.bundle"), 2246)
        XCTAssertNil(CacheJanitor.writerProcess(of: "a1b2.bundle"))
    }

    func testRemovesOnlyCopiesFromEndedProcesses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = root.appendingPathComponent("26B131/abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: hash, withIntermediateDirectories: true)
        for name in ["model.bundle", "model.tmp.100_0.bundle", "model.tmp.200_0.bundle"] {
            try FileManager.default.createDirectory(at: hash.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let abandoned = CacheJanitor.abandonedCopies(in: root) { $0 == 200 }
        XCTAssertEqual(abandoned.map(\.lastPathComponent), ["model.tmp.100_0.bundle"])
    }

    func testRecognisesMacOSBuildFolders() {
        XCTAssertTrue(CacheJanitor.looksLikeBuild("26B131"))
        XCTAssertTrue(CacheJanitor.looksLikeBuild("25A354"))
        XCTAssertFalse(CacheJanitor.looksLikeBuild("models"))
    }
}
