import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: TimeInterval
    var note: String
    /// The transcript line this flag points at. Set once the transcript exists, so it can lag the flag by a moment.
    var segmentID: UUID?
    /// The line's original words when the flag was anchored, kept in case the line itself is ever gone.
    var excerpt: String?
}

struct Meeting: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var joinURL: URL?
    var attendees: [String]
    var aiNotes = false
    var notes = ""
    var bookmarks: [Bookmark] = []
    /// Nil until you say. When true, the microphone track is split into the voices in the room.
    var inPerson: Bool?
    /// How many people were in the room, when you've said. Nil lets the app work it out.
    var expectedSpeakers: Int?

    var endDate: Date { endedAt ?? startedAt }
}

extension Meeting {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        joinURL = try container.decodeIfPresent(URL.self, forKey: .joinURL)
        attendees = try container.decodeIfPresent([String].self, forKey: .attendees) ?? []
        aiNotes = try container.decodeIfPresent(Bool.self, forKey: .aiNotes) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        bookmarks = try container.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        inPerson = try container.decodeIfPresent(Bool.self, forKey: .inPerson)
        expectedSpeakers = try container.decodeIfPresent(Int.self, forKey: .expectedSpeakers)
    }
}

struct ActionItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var task: String
    var owner: String?
    var due: String?
}

struct MeetingNotes: Codable, Hashable {
    var summary: String
    var decisions: [String]
    var actionItems: [ActionItem]
    var generatedAt: Date
    var model: String
}

/// Everything lives under `<dataFolder>/meetings/<id>/`. Nothing is written anywhere else.
enum MeetingStore {
    static let micFileName = "mic.m4a"
    static let systemFileName = "system.m4a"
    static let transcriptFileName = "transcript.json"
    static let notesFileName = "notes.json"
    static let markdownFileName = "meeting.md"
    static let diagnosticsFileName = "diagnostics.json"
    private static let metaFileName = "meta.json"

    static func meetingsRoot(in dataFolder: URL) -> URL {
        dataFolder.appendingPathComponent("meetings", isDirectory: true)
    }

    static func folder(for id: UUID, in dataFolder: URL) -> URL {
        meetingsRoot(in: dataFolder).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func audioURL(_ track: AudioTrack, for meeting: Meeting, in dataFolder: URL) -> URL {
        folder(for: meeting.id, in: dataFolder)
            .appendingPathComponent(track == .mic ? micFileName : systemFileName)
    }

    static func load(in dataFolder: URL) -> [Meeting] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: meetingsRoot(in: dataFolder),
            includingPropertiesForKeys: nil
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return directories
            .compactMap { directory -> Meeting? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(metaFileName)) else {
                    return nil
                }
                return try? decoder.decode(Meeting.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func save(_ meeting: Meeting, in dataFolder: URL) throws {
        let directory = folder(for: meeting.id, in: dataFolder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meeting).write(to: directory.appendingPathComponent(metaFileName), options: .atomic)
    }

    static func loadTranscript(_ meeting: Meeting, in dataFolder: URL) -> TranscriptFile {
        let url = folder(for: meeting.id, in: dataFolder).appendingPathComponent(transcriptFileName)
        guard let data = try? Data(contentsOf: url) else { return TranscriptFile() }
        return (try? JSONDecoder().decode(TranscriptFile.self, from: data)) ?? TranscriptFile()
    }

    static func saveTranscript(_ file: TranscriptFile, for meeting: Meeting, in dataFolder: URL) throws {
        let directory = folder(for: meeting.id, in: dataFolder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: directory.appendingPathComponent(transcriptFileName), options: .atomic)
    }

    static func loadNotes(_ meeting: Meeting, in dataFolder: URL) -> MeetingNotes? {
        let url = folder(for: meeting.id, in: dataFolder).appendingPathComponent(notesFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingNotes.self, from: data)
    }

    static func saveNotes(_ notes: MeetingNotes, for meeting: Meeting, in dataFolder: URL) throws {
        let directory = folder(for: meeting.id, in: dataFolder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(notes).write(to: directory.appendingPathComponent(notesFileName), options: .atomic)
    }

    static func loadDiagnostics(_ meeting: Meeting, in dataFolder: URL) -> MeetingDiagnostics? {
        let url = folder(for: meeting.id, in: dataFolder).appendingPathComponent(diagnosticsFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingDiagnostics.self, from: data)
    }

    static func saveDiagnostics(_ diagnostics: MeetingDiagnostics, for meeting: Meeting, in dataFolder: URL) {
        let directory = folder(for: meeting.id, in: dataFolder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(diagnostics) {
            try? data.write(to: directory.appendingPathComponent(diagnosticsFileName), options: .atomic)
        }
    }

    static func writeMarkdown(_ markdown: String, for meeting: Meeting, in dataFolder: URL) {
        let url = folder(for: meeting.id, in: dataFolder).appendingPathComponent(markdownFileName)
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    static func hasAudio(_ meeting: Meeting, in dataFolder: URL) -> Bool {
        let directory = folder(for: meeting.id, in: dataFolder)
        return [micFileName, systemFileName].contains { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    static func hasTranscript(_ meeting: Meeting, in dataFolder: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: folder(for: meeting.id, in: dataFolder).appendingPathComponent(transcriptFileName).path
        )
    }

    static func deleteAudio(_ meeting: Meeting, in dataFolder: URL) throws {
        let directory = folder(for: meeting.id, in: dataFolder)
        for name in [micFileName, systemFileName] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func delete(_ meeting: Meeting, in dataFolder: URL) throws {
        try FileManager.default.removeItem(at: folder(for: meeting.id, in: dataFolder))
    }
}
