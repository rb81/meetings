import XCTest

@testable import Meetings

private func words(_ text: String, from start: Double) -> [SegmentWord] {
    text.split(separator: " ").enumerated().map { index, word in
        SegmentWord(text: String(word), start: start + Double(index) * 0.3, end: start + Double(index) * 0.3 + 0.25)
    }
}

private func line(_ speaker: String, _ text: String, at start: Double) -> TranscriptSegment {
    let list = words(text, from: start)
    return TranscriptSegment(
        track: .mic,
        start: start,
        end: list.last!.end,
        text: text,
        speakerID: speaker,
        cleaned: "cleaned",
        words: list
    )
}

private struct ScriptedModel: LanguageModel {
    let promptBudget = 6_000
    let label = "Test"
    let reply: @Sendable (String) -> String

    func complete(system: String, user: String, json: Bool) async throws -> String { reply(system) }
}

final class SpeakerPolishTests: XCTestCase {
    func testCutOffSentenceFinishedByTheNextVoiceIsACandidate() {
        let a = line("S1", "So I think we", at: 0)
        let b = line("S2", "should, Absolutely agree with that.", at: 1.3)
        let found = SpeakerPolish.candidates(in: [a, b])
        XCTAssertEqual(found, [.init(before: a.id, after: b.id, count: 1, direction: .headToBefore)])
    }

    func testSentenceStartedTooEarlyIsACandidate() {
        let a = line("S1", "That works for me. So what", at: 0)
        let b = line("S2", "do we do next?", at: 1.9)
        let found = SpeakerPolish.candidates(in: [a, b])
        XCTAssertEqual(found, [.init(before: a.id, after: b.id, count: 2, direction: .tailToAfter)])
    }

    func testCleanChangeIsNotACandidate() {
        let a = line("S1", "That works for me.", at: 0)
        let b = line("S2", "Great, let's move on.", at: 1.3)
        XCTAssertTrue(SpeakerPolish.candidates(in: [a, b]).isEmpty)
    }

    func testSameSpeakerOrLongPauseIsNotACandidate() {
        let a = line("S1", "So I think we", at: 0)
        XCTAssertTrue(SpeakerPolish.candidates(in: [a, line("S1", "should, yes. Agreed.", at: 1.3)]).isEmpty)
        XCTAssertTrue(SpeakerPolish.candidates(in: [a, line("S2", "should, yes. Agreed.", at: 5)]).isEmpty)
    }

    func testLinesYouMovedAreLeftAlone() {
        let a = line("S1", "So I think we", at: 0)
        var b = line("S2", "should, Absolutely agree with that.", at: 1.3)
        b.pinned = true
        XCTAssertTrue(SpeakerPolish.candidates(in: [a, b]).isEmpty)
    }

    func testMovingWordsKeepsThemExactly() {
        let a = line("S1", "So I think we", at: 0)
        let b = line("S2", "should, Absolutely agree with that.", at: 1.3)
        let boundary = SpeakerPolish.Boundary(before: a.id, after: b.id, count: 1, direction: .headToBefore)
        let result = SpeakerPolish.apply(boundary, to: [a, b])
        XCTAssertEqual(result[0].text, "So I think we should,")
        XCTAssertEqual(result[1].text, "Absolutely agree with that.")
        XCTAssertNil(result[0].cleaned)
        XCTAssertNil(result[1].cleaned)
        XCTAssertEqual(result[0].end, b.words![0].end)
        XCTAssertEqual(result[1].start, b.words![1].start)
        XCTAssertEqual(result[0].speakerID, "S1")
        XCTAssertEqual(result[1].speakerID, "S2")
    }

    func testRepliesAreReadLeniently() {
        XCTAssertEqual(SpeakerPolish.parseMoves(#"Sure: {"yes": [1, "3"]}"#), [1, 3])
        XCTAssertEqual(SpeakerPolish.parseMoves("no idea"), [])
    }

    func testOnlyNamesSaidInTheMeetingAreSuggested() {
        let reply = #"{"names": {"S1": "Dana", "S2": "Bob", "S3": "dana smith", "S4": "Lee", "S9": "Ann"}}"#
        let result = SpeakerPolish.validNames(
            reply,
            transcript: "Hi, I'm Dana. Thanks Lee. Ann here.",
            speakers: ["S1", "S2", "S3", "S4"],
            named: ["S4": "Lee"]
        )
        XCTAssertEqual(result, ["S1": "Dana"])
    }

    func testNameOfferedForTwoSpeakersIsDropped() {
        let result = SpeakerPolish.validNames(
            #"{"names": {"S1": "Dana", "S2": "Dana"}}"#,
            transcript: "I'm Dana",
            speakers: ["S1", "S2"],
            named: [:]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testRunAppliesOnlyWhatTheModelConfirms() async {
        let a = line("S1", "So I think we", at: 0)
        let b = line("S2", "should, Absolutely agree with that. I'm Dana by the way.", at: 1.3)
        let model = ScriptedModel { system in
            system == SpeakerPolish.boundarySystem ? #"{"yes": [1]}"# : #"{"names": {"S2": "Dana"}}"#
        }
        let result = await SpeakerPolish.run(segments: [a, b], speakerNames: [:], model: model, tidy: true, suggest: true)
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.segments[0].text, "So I think we should,")
        XCTAssertEqual(result.suggestedNames, ["S2": "Dana"])
    }

    func testRunLeavesEverythingWhenTheModelSaysNo() async {
        let a = line("S1", "So I think we", at: 0)
        let b = line("S2", "should, Absolutely agree with that.", at: 1.3)
        let model = ScriptedModel { _ in #"{"yes": []}"# }
        let result = await SpeakerPolish.run(segments: [a, b], speakerNames: [:], model: model, tidy: true, suggest: false)
        XCTAssertEqual(result.segments, [a, b])
        XCTAssertTrue(result.suggestedNames.isEmpty)
    }
}

final class SpeakerScoreTests: XCTestCase {
    private typealias Turn = SpeakerAssignment.Turn

    func testPerfectAnswerWithOtherNumbersScoresZero() {
        let reference = [Turn(speaker: "alice", start: 0, end: 5), Turn(speaker: "bob", start: 5, end: 10)]
        let hypothesis = [Turn(speaker: "S2", start: 0, end: 5), Turn(speaker: "S1", start: 5, end: 10)]
        XCTAssertEqual(SpeakerScore.der(reference: reference, hypothesis: hypothesis).der, 0, accuracy: 1e-9)
    }

    func testErrorsAreSplitByKind() {
        let reference = [Turn(speaker: "a", start: 0, end: 10), Turn(speaker: "b", start: 10, end: 20)]
        let hypothesis = [
            Turn(speaker: "x", start: 0, end: 8),  // 2 s of a missed
            Turn(speaker: "x", start: 10, end: 12), // 2 s of b given to a
            Turn(speaker: "y", start: 12, end: 20),
            Turn(speaker: "y", start: 20, end: 21), // 1 s invented
        ]
        let score = SpeakerScore.der(reference: reference, hypothesis: hypothesis)
        XCTAssertEqual(score.speech, 20, accuracy: 0.01)
        XCTAssertEqual(score.missed, 2, accuracy: 0.01)
        XCTAssertEqual(score.confusion, 2, accuracy: 0.01)
        XCTAssertEqual(score.falseAlarm, 1, accuracy: 0.01)
        XCTAssertEqual(score.der, 0.25, accuracy: 0.001)
    }

    func testCollarForgivesEdges() {
        let reference = [Turn(speaker: "a", start: 0, end: 5), Turn(speaker: "b", start: 5, end: 10)]
        let hypothesis = [Turn(speaker: "x", start: 0, end: 5.2), Turn(speaker: "y", start: 5.2, end: 10)]
        XCTAssertGreaterThan(SpeakerScore.der(reference: reference, hypothesis: hypothesis).der, 0)
        XCTAssertEqual(SpeakerScore.der(reference: reference, hypothesis: hypothesis, collar: 0.25).der, 0, accuracy: 1e-9)
    }

    func testOneVoiceSplitInTwoCountsAsConfusion() {
        let reference = [Turn(speaker: "a", start: 0, end: 10)]
        let hypothesis = [Turn(speaker: "x", start: 0, end: 6), Turn(speaker: "y", start: 6, end: 10)]
        XCTAssertEqual(SpeakerScore.der(reference: reference, hypothesis: hypothesis).der, 0.4, accuracy: 0.001)
    }

    func testWordErrorUsesTheBestMatch() {
        let reference = ["a", "a", "b", "b", "c"]
        XCTAssertEqual(SpeakerScore.wordError(reference: reference, hypothesis: ["S2", "S2", "S1", "S1", "S3"]), 0)
        XCTAssertEqual(SpeakerScore.wordError(reference: reference, hypothesis: ["S1", "S1", "S1", "S2", nil]), 0.4, accuracy: 1e-9)
    }

    func testRTTMIsRead() {
        let text = """
        SPEAKER meeting 1 0.50 2.00 <NA> <NA> alice <NA> <NA>
        ; a comment
        SPEAKER meeting 1 3.00 1.25 <NA> <NA> bob <NA> <NA>
        """
        XCTAssertEqual(SpeakerScore.parseRTTM(text), [
            Turn(speaker: "alice", start: 0.5, end: 2.5),
            Turn(speaker: "bob", start: 3, end: 4.25),
        ])
    }
}

/// Scores the real in-person pipeline on labelled recordings. Put `name.wav` and `name.rttm` pairs in
/// `MeetingsTests/Fixtures/Scoring` (ignored by git), or point `MEETINGS_SCORING_DIR` at a folder of them.
/// The models are read from `MEETINGS_MODELS_DIR`, or the app's data folder. Skipped without recordings.
@MainActor
final class SpeakerPipelineScoringTests: XCTestCase {
    func testScoreLabelledRecordings() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtures = environment["MEETINGS_SCORING_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Scoring", isDirectory: true)
        let recordings = ((try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
            .filter { FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("rttm").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(recordings.isEmpty, "No labelled recordings in \(fixtures.path)")

        let modelsFolder = environment["MEETINGS_MODELS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (UserDefaults.standard.string(forKey: "dataFolderPath").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? AppSettings.defaultFolder).appendingPathComponent("models", isDirectory: true)
        let loaded = await ModelManager.loadRoomModels(in: modelsFolder)
        let models = try XCTUnwrap(loaded, "In-person speaker models aren't downloaded in \(modelsFolder.path)")

        var total = SpeakerScore.Breakdown()
        for recording in recordings {
            let reference = SpeakerScore.parseRTTM(
                try String(contentsOf: recording.deletingPathExtension().appendingPathExtension("rttm"), encoding: .utf8)
            )
            let people = Set(reference.map(\.speaker)).count
            var notes: [String] = []
            let started = Date()
            let pass = await SpeakerLabeler.carefulPass(
                recording,
                models: RoomModels(speakers: models.speakers, prints: models.prints),
                expected: nil,
                notes: &notes,
                onProgress: { _ in }
            )
            let result = try XCTUnwrap(pass, notes.joined(separator: " "))
            let hypothesis = result.activity.turns()
            let score = SpeakerScore.der(reference: reference, hypothesis: hypothesis, collar: 0.25)
            let heard = Set(hypothesis.map(\.speaker)).count
            print(String(
                format: "[score] %@: DER %.1f%% (missed %.1f, false alarm %.1f, confusion %.1f), %d of %d people, %d joined, %.1fs",
                recording.lastPathComponent, score.der * 100,
                score.missed / max(score.speech, 1) * 100,
                score.falseAlarm / max(score.speech, 1) * 100,
                score.confusion / max(score.speech, 1) * 100,
                heard, people, result.merged, Date().timeIntervalSince(started)
            ))
            total.speech += score.speech
            total.missed += score.missed
            total.falseAlarm += score.falseAlarm
            total.confusion += score.confusion
        }
        print(String(format: "[score] overall DER %.1f%% over %.0f s of speech", total.der * 100, total.speech))
    }
}
