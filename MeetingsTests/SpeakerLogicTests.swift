import XCTest

@testable import Meetings

final class SpeakerAssignmentTests: XCTestCase {
    private typealias Turn = SpeakerAssignment.Turn

    func testLongestOverlapWins() {
        let turns = [
            Turn(speaker: "0", start: 0, end: 4),
            Turn(speaker: "1", start: 4, end: 10),
        ]
        XCTAssertEqual(SpeakerAssignment.speaker(start: 3, end: 9, turns: turns), "1")
    }

    func testNearestVoiceTakesALineThatMissesEveryTurn() {
        let turns = [
            Turn(speaker: "0", start: 0, end: 4),
            Turn(speaker: "1", start: 20, end: 30),
        ]
        XCTAssertEqual(SpeakerAssignment.speaker(start: 5, end: 6, turns: turns), "0")
    }

    func testLineFarFromAnyVoiceStaysUnassigned() {
        let turns = [Turn(speaker: "0", start: 0, end: 4)]
        XCTAssertNil(SpeakerAssignment.speaker(start: 30, end: 32, turns: turns))
    }

    func testNoTurnsMeansNoSpeaker() {
        XCTAssertNil(SpeakerAssignment.speaker(start: 0, end: 5, turns: []))
    }

    func testWhoeverSpeaksFirstIsSpeakerOne() {
        let a = UUID(), b = UUID(), c = UUID()
        // The model's own slot names don't matter, only who is heard first.
        let result = SpeakerAssignment.numberByAppearance([a: "x", b: "y", c: "x"], order: [b, a, c])
        XCTAssertEqual(result["y"], "S1")
        XCTAssertEqual(result["x"], "S2")
    }

    func testNumbersHaveNoGaps() {
        let ids = (0..<4).map { _ in UUID() }
        let voices = Dictionary(uniqueKeysWithValues: zip(ids, ["7", "3", "7", "5"]))
        let result = SpeakerAssignment.numberByAppearance(voices, order: ids)
        XCTAssertEqual(Set(result.values), ["S1", "S2", "S3"])
    }

    func testRelinkFollowsThePersonWhenNumbersSwap() {
        let a = UUID(), b = UUID(), c = UUID()
        let result = SpeakerAssignment.relink(
            old: [a: "S2", b: "S1", c: "S1"],
            new: [a: "S1", b: "S2", c: "S2"],
            weights: [a: 5, b: 5, c: 5]
        )
        XCTAssertEqual(result, ["S2": "S1", "S1": "S2"])
    }

    func testVoiceMergedAwayKeepsNoID() {
        let a = UUID(), b = UUID()
        // Live heard two voices, the careful pass one. Only the one that spoke more keeps the link.
        let result = SpeakerAssignment.relink(old: [a: "S1", b: "S2"], new: [a: "S1", b: "S1"], weights: [a: 9, b: 3])
        XCTAssertEqual(result, ["S1": "S1"])
    }
}

/// Builds activity from a rule giving each voice's likelihood in each 10 ms frame.
private func activity(frames: Int, slots: Int = 3, _ value: (Int, Int) -> Float) -> SpeakerActivity {
    var values: [Float] = []
    for frame in 0..<frames {
        for slot in 0..<slots { values.append(value(frame, slot)) }
    }
    return SpeakerActivity(slots: slots, values: values)
}

final class SpeakerActivityTests: XCTestCase {
    private let twoVoices = activity(frames: 200) { frame, slot in
        (slot == 0 && frame < 100) || (slot == 1 && frame >= 100) ? 0.9 : 0
    }

    func testWordGoesToTheClearestVoice() {
        XCTAssertEqual(twoVoices.voice(start: 0.2, end: 0.8), 0)
        XCTAssertEqual(twoVoices.voice(start: 1.1, end: 1.9), 1)
        XCTAssertEqual(twoVoices.voice(start: 0.9, end: 1.3), 1)
    }

    func testQuietWordGoesToTheNearestVoice() {
        let speech = activity(frames: 300) { frame, slot in slot == 0 && frame < 100 ? 0.9 : 0 }
        XCTAssertEqual(speech.voice(start: 1.2, end: 1.5, maxGap: 0.5), 0)
        XCTAssertNil(speech.voice(start: 2.5, end: 2.9, maxGap: 0.5))
    }

    func testWobbleAndShortPauseStayOneTurn() {
        let speech = activity(frames: 250) { frame, slot in
            guard slot == 0 else { return 0 }
            switch frame {
            case 0..<50, 80..<100, 120..<200: return 0.9
            case 50..<80: return 0.4
            default: return 0
            }
        }
        let turns = speech.turns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.speaker, "0")
        XCTAssertEqual(turns.first?.start ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(turns.first?.end ?? -1, 2.0, accuracy: 0.001)
    }

    func testBlipIsNotATurn() {
        let speech = activity(frames: 100) { frame, slot in slot == 1 && (50..<60).contains(frame) ? 0.9 : 0 }
        XCTAssertTrue(speech.turns().isEmpty)
    }

    func testArrivalOrderIgnoresFalseStarts() {
        let speech = activity(frames: 300) { frame, slot in
            switch slot {
            case 2: return frame < 20 || frame >= 200 ? 0.9 : 0
            case 1: return (50..<150).contains(frame) ? 0.9 : 0
            default: return 0
            }
        }
        XCTAssertEqual(speech.arrivalOrder(), [1, 2])
    }

    func testSoloStretchesSkipOverlap() {
        let speech = activity(frames: 300) { frame, slot in
            switch slot {
            case 0: return 0.9
            case 1: return (100..<150).contains(frame) ? 0.9 : 0
            default: return 0
            }
        }
        let stretches = speech.soloStretches(slot: 0)
        XCTAssertEqual(stretches.count, 2)
        XCTAssertEqual(stretches[0].lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(stretches[0].upperBound, 1.0, accuracy: 0.001)
        XCTAssertEqual(stretches[1].lowerBound, 1.5, accuracy: 0.001)
        XCTAssertEqual(stretches[1].upperBound, 3.0, accuracy: 0.001)
    }

    func testLongSoloSpeechIsCutIntoPieces() {
        let speech = activity(frames: 2_000, slots: 1) { _, _ in 0.9 }
        let stretches = speech.soloStretches(slot: 0, longest: 8)
        XCTAssertEqual(stretches.count, 3)
        XCTAssertTrue(stretches.allSatisfy { $0.upperBound - $0.lowerBound <= 8.001 })
    }

    func testMergingAddsAndRemovesVoices() {
        let speech = activity(frames: 10) { _, slot in [0.6, 0.5, 0.3][slot] }
        let merged = speech.merging([1: 0, 2: nil])
        XCTAssertEqual(merged.probability(frame: 3, slot: 0), 1)
        XCTAssertEqual(merged.probability(frame: 3, slot: 1), 0)
        XCTAssertEqual(merged.probability(frame: 3, slot: 2), 0)
    }
}

final class VoiceMergerTests: XCTestCase {
    private func voice(_ slot: Int, _ seconds: Double, _ print: [Float]?) -> VoiceMerger.Voice {
        VoiceMerger.Voice(slot: slot, seconds: seconds, print: print.map(VoiceMerger.normalized))
    }

    func testSameVoiceIsJoinedIntoTheOneThatSpokeMore() {
        let plan = VoiceMerger.plan(voices: [voice(0, 10, [1, 0, 0]), voice(1, 30, [0.95, 0.31, 0])], expected: nil)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0] ?? nil, 1)
    }

    func testDifferentVoicesStayApart() {
        let plan = VoiceMerger.plan(voices: [voice(0, 10, [1, 0, 0]), voice(1, 30, [0, 1, 0])], expected: nil)
        XCTAssertTrue(plan.isEmpty)
    }

    func testExpectedCountJoinsTheMostAlikeVoices() {
        let voices = [voice(0, 20, [1, 0, 0]), voice(1, 20, [0, 1, 0]), voice(2, 5, [0.5, 0.1, 0.86])]
        let plan = VoiceMerger.plan(voices: voices, expected: 2)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[2] ?? nil, 0)
    }

    func testBriefVoiceWithoutAPrintIsDroppedFirst() {
        let voices = [voice(0, 20, [1, 0, 0]), voice(1, 20, [0, 1, 0]), voice(2, 1, nil)]
        let plan = VoiceMerger.plan(voices: voices, expected: 2)
        XCTAssertEqual(plan.count, 1)
        XCTAssertTrue(plan.keys.contains(2))
        XCTAssertNil(plan[2]!)
    }

    func testVoiceWithoutAPrintIsKeptWhenNobodySaidHowMany() {
        let voices = [voice(0, 20, [1, 0, 0]), voice(1, 1, nil)]
        XCTAssertTrue(VoiceMerger.plan(voices: voices, expected: nil).isEmpty)
    }
}

final class AutoGainTests: XCTestCase {
    func testQuietSpeechIsLifted() {
        let gain = AutoGain()
        let quiet = [Float](repeating: 0.01, count: 1_600)
        let lifted = gain.apply(quiet)
        XCTAssertGreaterThan(AudioLevel.rms(lifted), AudioLevel.rms(quiet) * 3)
    }

    func testSilenceIsNeverAmplified() {
        let gain = AutoGain()
        let hiss = [Float](repeating: 0.0005, count: 1_600)
        XCTAssertEqual(gain.apply(hiss), hiss)
    }

    func testLoudSpeechIsLeftAlone() {
        let gain = AutoGain()
        let loud = [Float](repeating: 0.2, count: 1_600)
        XCTAssertEqual(gain.apply(loud), loud)
    }

    func testOutputNeverClips() {
        let gain = AutoGain()
        _ = gain.apply([Float](repeating: 0.005, count: 1_600))
        let spike = gain.apply([Float](repeating: 0.5, count: 1_600))
        XCTAssertTrue(spike.allSatisfy { abs($0) <= 1 })
    }
}

final class RecordingClockTests: XCTestCase {
    func testClockStopsWhilePaused() {
        let clock = RecordingClock()
        clock.start()
        clock.pause()
        let soon = clock.elapsed(at: .now)
        let muchLater = clock.elapsed(at: .now.addingTimeInterval(600))
        XCTAssertEqual(soon, muchLater, accuracy: 0.05)
    }

    func testNothingElapsesBeforeStart() {
        XCTAssertEqual(RecordingClock().elapsed(at: .now.addingTimeInterval(100)), 0)
    }

    func testResetClearsTheClock() {
        let clock = RecordingClock()
        clock.start()
        clock.reset()
        XCTAssertEqual(clock.elapsed(at: .now.addingTimeInterval(100)), 0)
    }
}

final class TranscriptLabelTests: XCTestCase {
    private func micLine(_ speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(track: .mic, start: 0, end: 2, text: "Hello there everyone", speakerID: speaker)
    }

    func testMicIsYouOnline() {
        XCTAssertEqual(TranscriptFile().label(for: micLine()), "You")
    }

    func testMicIsTheRoomInPerson() {
        XCTAssertEqual(TranscriptFile(mixedMic: true).label(for: micLine()), "Room")
    }

    func testSeparatedVoicesAreNumbered() {
        XCTAssertEqual(TranscriptFile(mixedMic: true).label(for: micLine("S2")), "Speaker 2")
    }

    func testRenamedSpeakerUsesItsName() {
        let file = TranscriptFile(speakerNames: ["S1": "Dana"], mixedMic: true)
        XCTAssertEqual(file.label(for: micLine("S1")), "Dana")
    }

    func testNextSpeakerIDSkipsExistingOnes() {
        let file = TranscriptFile(segments: [micLine("S1"), micLine("S3")])
        XCTAssertEqual(file.nextSpeakerID, "S4")
    }
}

final class DiagnosticsTests: XCTestCase {
    func testSilentMicrophoneIsReported() {
        let report = MeetingDiagnostics(
            inPerson: true,
            mic: TrackDiagnostics(seconds: 120, peakDecibels: -80, averageDecibels: -90, speechSeconds: 0, lines: 0)
        )
        XCTAssertNotNil(report.concern)
        XCTAssertTrue(report.concern?.contains("almost silent") == true)
    }

    func testAudibleButUnheardSpeechIsReported() {
        let report = MeetingDiagnostics(
            inPerson: true,
            mic: TrackDiagnostics(seconds: 120, peakDecibels: -30, averageDecibels: -45, speechSeconds: 0, lines: 0)
        )
        XCTAssertTrue(report.concern?.contains("no speech was detected") == true)
    }

    func testHealthyRecordingHasNoConcern() {
        let report = MeetingDiagnostics(
            inPerson: false,
            mic: TrackDiagnostics(seconds: 120, peakDecibels: -10, averageDecibels: -30, speechSeconds: 60, lines: 20)
        )
        XCTAssertNil(report.concern)
    }

    func testShortRecordingsAreNotFlagged() {
        let report = MeetingDiagnostics(
            mic: TrackDiagnostics(seconds: 5, peakDecibels: -80, averageDecibels: -90, speechSeconds: 0, lines: 0)
        )
        XCTAssertNil(report.concern)
    }
}

final class SegmentSplitterTests: XCTestCase {
    private typealias Turn = SpeakerAssignment.Turn

    /// Ten words, 0.4 s apart, so word `n` is spoken between `0.4n` and `0.4n + 0.35`.
    private func line(wordCount: Int = 10) -> TranscriptSegment {
        let words = (0..<wordCount).map {
            SegmentWord(text: "w\($0)", start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.35)
        }
        return TranscriptSegment(
            track: .mic,
            start: 0,
            end: Double(wordCount) * 0.4,
            text: words.map(\.text).joined(separator: " "),
            speakerID: "S1",
            cleaned: "cleaned text",
            words: words
        )
    }

    func testLineIsCutWhereTheVoiceChanges() {
        let turns = [Turn(speaker: "0", start: 0, end: 2.0), Turn(speaker: "1", start: 2.0, end: 4.0)]
        let original = line()
        let pieces = SegmentSplitter.split(original, turns: turns)

        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].text, "w0 w1 w2 w3 w4")
        XCTAssertEqual(pieces[1].text, "w5 w6 w7 w8 w9")
        XCTAssertEqual(pieces[0].id, original.id)
        XCTAssertNotEqual(pieces[1].id, original.id)
    }

    func testPiecesCarryNoSpeakerOrCleanedText() {
        let turns = [Turn(speaker: "0", start: 0, end: 2.0), Turn(speaker: "1", start: 2.0, end: 4.0)]
        for piece in SegmentSplitter.split(line(), turns: turns) {
            XCTAssertNil(piece.speakerID)
            XCTAssertNil(piece.cleaned)
        }
    }

    func testPiecesCoverTheWholeLine() {
        let turns = [Turn(speaker: "0", start: 0, end: 2.0), Turn(speaker: "1", start: 2.0, end: 4.0)]
        let original = line()
        let pieces = SegmentSplitter.split(original, turns: turns)
        XCTAssertEqual(pieces.first?.start, original.start)
        XCTAssertEqual(pieces.last?.end, original.end)
    }

    func testOneVoiceLeavesTheLineAlone() {
        let original = line()
        XCTAssertEqual(SegmentSplitter.split(original, turns: [Turn(speaker: "0", start: 0, end: 4)]), [original])
    }

    func testBriefBlipIsNotACut() {
        // Only word 4 (1.6 to 1.95 s) falls in the other voice's turn, so it is a one-word stretch and gets absorbed.
        let original = line()
        let turns = [
            Turn(speaker: "0", start: 0, end: 1.55),
            Turn(speaker: "1", start: 1.55, end: 1.97),
            Turn(speaker: "0", start: 1.97, end: 4),
        ]
        XCTAssertEqual(SegmentSplitter.split(original, turns: turns).count, 1)
    }

    func testEachWordCanBeLabelledOnItsOwn() {
        let pieces = SegmentSplitter.split(line()) { $0.start < 2.0 ? "a" : "b" }
        XCTAssertEqual(pieces.map { $0.words?.count }, [5, 5])
        XCTAssertEqual(pieces[1].text, "w5 w6 w7 w8 w9")
    }

    func testLineWithoutWordTimingsIsUntouched() {
        var original = line()
        original.words = nil
        let turns = [Turn(speaker: "0", start: 0, end: 2), Turn(speaker: "1", start: 2, end: 4)]
        XCTAssertEqual(SegmentSplitter.split(original, turns: turns), [original])
    }

    func testNoTurnsLeavesTheLineAlone() {
        let original = line()
        XCTAssertEqual(SegmentSplitter.split(original, turns: []), [original])
    }
}

final class AutoGainSmoothnessTests: XCTestCase {
    func testSteadySpeechIsNotPumped() {
        let gain = AutoGain()
        let chunk = [Float](repeating: 0.01, count: 1_600)
        let first = AudioLevel.rms(gain.apply(chunk))
        var last = first
        for _ in 0..<30 { last = AudioLevel.rms(gain.apply(chunk)) }
        XCTAssertEqual(first, last, accuracy: 0.002)
    }

    func testPeaksAreRoundedNotClipped() {
        let gain = AutoGain()
        _ = gain.apply([Float](repeating: 0.01, count: 1_600))
        let loud = gain.apply([Float](repeating: 0.2, count: 1_600))
        XCTAssertTrue(loud.allSatisfy { abs($0) <= 1 })
    }
}
