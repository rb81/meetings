import AppKit
import Carbon.HIToolbox
import Observation
import os

enum SidebarItem: Hashable {
    case upcoming
    case meeting(UUID)
}

/// An in-person meeting waiting on the speaker models: either the question about downloading them, or the
/// download itself.
struct PendingStart: Equatable {
    let id = UUID()
    let title: String
    let joinURL: URL?
    let attendees: [String]
}

enum SpeakerModelChoice {
    case download
    case startWithout
    case cancel
}

struct SearchHit: Identifiable {
    let meeting: Meeting
    let snippet: String?
    var id: UUID { meeting.id }
}

@MainActor
@Observable
final class AppStore {
    let settings = AppSettings()
    let calendar = CalendarService()
    let recorder = Recorder()
    let models = ModelManager()
    let updates = UpdateService()
    let playback = AudioPlayback()

    @ObservationIgnored let levels = LevelMeter()
    @ObservationIgnored private lazy var notifications = NotificationService()
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var searchCache: [UUID: String] = [:]
    @ObservationIgnored private var searchCacheRevision = -1
    @ObservationIgnored private let log = Logger(subsystem: "com.rakan.Meetings", category: "app")

    var selection: SidebarItem? = .upcoming
    var errorMessage: String?
    var searchText = ""

    private(set) var meetings: [Meeting] = []
    private(set) var activeMeetingID: UUID?
    private(set) var liveFile = TranscriptFile()
    private(set) var isTranscribingLive = false
    private(set) var isFinalizing = false
    private(set) var processing: [UUID: String] = [:]
    private(set) var revision = 0
    private(set) var hasOpenRouterKey = false
    private(set) var hasCompatibleKey = false
    private(set) var remindersBlocked = false
    /// True while voices are being told apart live, which only happens in person.
    private(set) var liveSpeakersActive = false
    /// Set when an in-person meeting was asked for but the speaker models are missing. The window asks what to do.
    var speakerModelPrompt: PendingStart?
    /// An in-person meeting that starts by itself once the speaker models finish downloading.
    private(set) var waitingToStart: PendingStart?
    /// Bumped to bring the main window forward, so a question asked from the menu bar is seen.
    private(set) var windowRequest = 0

    private var transcriber: LiveTranscriber?
    @ObservationIgnored private var speakerTracker: LiveSpeakerTracker?
    @ObservationIgnored private var stats: RecordingStats?
    /// Lines you moved by hand while recording. Live speaker updates leave these alone.
    @ObservationIgnored private var pinnedSegments = Set<UUID>()
    /// During an in-person meeting, the live model's voice for each line, and the speaker ID each voice shows as.
    @ObservationIgnored private var liveVoices: [UUID: Int] = [:]
    @ObservationIgnored private var liveNumbers: [Int: String] = [:]
    @ObservationIgnored private var pauseHotKey: GlobalHotKey?
    @ObservationIgnored private var isPreview = false

    #if DEBUG
    @ObservationIgnored var previewTranscript: TranscriptFile?
    @ObservationIgnored var previewNotes: MeetingNotes?
    #endif

    /// `preview` skips every side effect (disk, hotkey, notifications, models) so SwiftUI previews stay isolated.
    init(preview: Bool = false) {
        isPreview = preview
        guard !preview else { return }

        refreshKeyFlags()
        reload()
        meetings.forEach { anchorBookmarks($0.id) }
        applyRetention()
        models.configure(dataFolder: settings.dataFolder)

        notifications.onJoin = { [weak self] request in
            guard let self else { return }
            Task {
                await self.startRecording(
                    title: request.title,
                    joinURL: request.joinURL,
                    attendees: request.attendees,
                    inPerson: request.joinURL == nil
                )
            }
        }
        hotKey = GlobalHotKey(
            keyCode: kVK_ANSI_M,
            modifiers: controlKey | optionKey | cmdKey,
            id: 1
        ) { [weak self] in
            Task { @MainActor in await self?.toggleRecording() }
        }
        pauseHotKey = GlobalHotKey(
            keyCode: kVK_ANSI_P,
            modifiers: controlKey | optionKey | cmdKey,
            id: 2
        ) { [weak self] in
            Task { @MainActor in self?.togglePause() }
        }
    }

    // MARK: - Lookup

    var activeMeeting: Meeting? {
        activeMeetingID.flatMap { id in meetings.first { $0.id == id } }
    }

    func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func hasAudio(_ meeting: Meeting) -> Bool {
        // Disk state isn't observable, so depend on `revision` to make views refresh when audio is deleted.
        _ = revision
        return MeetingStore.hasAudio(meeting, in: settings.dataFolder)
    }

    func transcript(for meeting: Meeting) -> TranscriptFile {
        #if DEBUG
        if let previewTranscript { return previewTranscript }
        #endif
        return meeting.id == activeMeetingID ? liveFile : MeetingStore.loadTranscript(meeting, in: settings.dataFolder)
    }

    func notes(for meeting: Meeting) -> MeetingNotes? {
        #if DEBUG
        if let previewNotes { return previewNotes }
        #endif
        return MeetingStore.loadNotes(meeting, in: settings.dataFolder)
    }

    func reload() {
        meetings = MeetingStore.load(in: settings.dataFolder)
    }

    func applyRetention() {
        RetentionService.apply(
            settings.audioRetention,
            in: settings.dataFolder,
            meetings: meetings,
            excluding: Set(processing.keys).union(activeMeetingID.map { [$0] } ?? [])
        )
        if let id = playback.meetingID, let meeting = meeting(id: id), !hasAudio(meeting) {
            playback.stop()
        }
        reload()
        bump()
    }

    private func bump() {
        revision += 1
    }

    // MARK: - Recording

    func startQuickRecording(inPerson: Bool = false) async {
        let now = Date.now
        if let current = calendar.events.first(where: { $0.start <= now.addingTimeInterval(300) && $0.end > now }) {
            await startRecording(title: current.title, joinURL: nil, attendees: current.attendees, inPerson: inPerson)
        } else {
            await startRecording(title: Format.untitled(), joinURL: nil, attendees: [], inPerson: inPerson)
        }
    }

    /// A calendar event with a meeting link is online. One without a link is assumed to be in the room.
    func record(_ event: CalendarEvent, inPerson: Bool? = nil) async {
        await startRecording(
            title: event.title,
            joinURL: inPerson == true ? nil : event.joinURL,
            attendees: event.attendees,
            inPerson: inPerson ?? (event.joinURL == nil)
        )
    }

    func resolveSpeakerModelPrompt(_ choice: SpeakerModelChoice) {
        guard let pending = speakerModelPrompt else { return }
        speakerModelPrompt = nil

        switch choice {
        case .download:
            startWhenModelsReady(pending)
        case .startWithout:
            Task { await start(pending) }
        case .cancel:
            break
        }
    }

    /// Downloads the in-person speaker models, then starts the meeting as soon as they're ready.
    private func startWhenModelsReady(_ pending: PendingStart) {
        guard let download = models.downloadRoomModels() else { return }
        waitingToStart = pending
        Task {
            let ready = await download.value
            // Started without the models, cancelled, or replaced by another meeting while downloading.
            guard waitingToStart == pending else { return }
            waitingToStart = nil
            if ready {
                await start(pending)
            } else {
                let reason = models.liveSpeakerIssue.map { " (\($0))" } ?? ""
                errorMessage = "The in-person speaker models couldn't be downloaded\(reason), so the meeting didn't start. Start it again to retry, or choose Start Without Them to record now."
            }
        }
    }

    /// Starts the meeting that is waiting on the download straight away. The download carries on, and the
    /// speakers are still separated after the meeting if it has finished by then.
    func startWaitingMeetingNow() {
        guard let pending = waitingToStart else { return }
        waitingToStart = nil
        Task { await start(pending) }
    }

    /// Stops waiting to start the meeting. The download carries on.
    func cancelWaitingMeeting() {
        waitingToStart = nil
    }

    private func start(_ pending: PendingStart) async {
        await startRecording(
            title: pending.title,
            joinURL: pending.joinURL,
            attendees: pending.attendees,
            inPerson: true,
            checkModels: false
        )
    }

    func toggleRecording() async {
        if recorder.isRecording {
            await stopRecording()
        } else {
            await startQuickRecording()
        }
    }

    func startRecording(
        title: String,
        joinURL: URL?,
        attendees: [String],
        inPerson: Bool = false,
        checkModels: Bool = true
    ) async {
        guard activeMeetingID == nil else { return }

        // In-person meetings need their speaker models. If they're missing, ask before starting, wherever
        // the meeting was started from. If they're already downloading, start once they're ready.
        if inPerson, checkModels, models.isReady, !models.hasRoomModels {
            let pending = PendingStart(title: title, joinURL: joinURL, attendees: attendees)
            if models.isDownloadingRoomModels {
                startWhenModelsReady(pending)
            } else {
                speakerModelPrompt = pending
            }
            windowRequest += 1
            return
        }

        var meeting = Meeting(
            id: UUID(),
            title: title,
            startedAt: .now,
            endedAt: nil,
            joinURL: joinURL,
            attendees: attendees
        )
        meeting.aiNotes = settings.aiNotesByDefault && aiReady
        meeting.inPerson = inPerson
        let started = meeting
        let dataFolder = settings.dataFolder

        liveFile = TranscriptFile(mixedMic: inPerson)
        levels.reset()
        pinnedSegments = []
        liveVoices = [:]
        liveNumbers = [:]

        let clock = recorder.clock
        let recordingStats = RecordingStats()
        stats = recordingStats

        var tracker: LiveSpeakerTracker?
        let live: LiveTranscriber?
        if let asr = models.asr, let vad = models.vad, models.isReady {
            if inPerson, let speakerModels = models.liveSpeakers {
                tracker = LiveSpeakerTracker(models: speakerModels) { [weak self] in
                    Task { @MainActor in self?.relabelRecent() }
                }
            }
            live = LiveTranscriber(
                asr: asr,
                vad: vad,
                clock: { clock.elapsed() },
                options: .forMeeting(inPerson: inPerson),
                stats: recordingStats,
                speakers: tracker
            ) { [weak self] segment in
                await self?.add(segment, to: started, in: dataFolder)
            }
        } else {
            live = nil
        }
        transcriber = live
        speakerTracker = tracker
        isTranscribingLive = live != nil
        liveSpeakersActive = tracker != nil

        let meter = levels
        let onAudio: AudioHandler = { track, samples in
            meter.update(track, samples: samples)
            if let live {
                live.feed(track, samples: samples)
            } else {
                recordingStats.record(track, samples: samples)
            }
        }

        if let joinURL {
            NSWorkspace.shared.open(joinURL)
        }

        do {
            try MeetingStore.save(meeting, in: dataFolder)
            try await recorder.start(
                into: MeetingStore.folder(for: meeting.id, in: dataFolder),
                echoCancellation: settings.echoCancellation && !inPerson,
                microphone: inPerson ? AudioInput.resolveInPerson(settings.inPersonInput) : AudioInput.Selection(),
                captureSystemAudio: !inPerson,
                onAudio: onAudio
            )
            reload()
            activeMeetingID = meeting.id
            selection = .meeting(meeting.id)
        } catch {
            await transcriber?.finish()
            await speakerTracker?.finish()
            transcriber = nil
            speakerTracker = nil
            stats = nil
            isTranscribingLive = false
            liveSpeakersActive = false
            try? MeetingStore.delete(meeting, in: dataFolder)
            errorMessage = error.localizedDescription
            reload()
        }
    }

    func stopRecording() async {
        guard let id = activeMeetingID, !isFinalizing else { return }
        isFinalizing = true

        await recorder.stop()
        await transcriber?.finish()
        await speakerTracker?.finish()
        relabelRecent(allLines: true)

        let voices = Set(liveVoices.values).count
        let liveActivity = speakerTracker?.activity() ?? SpeakerActivity()
        transcriber = nil
        speakerTracker = nil
        isTranscribingLive = false
        liveSpeakersActive = false

        update(id) { $0.endedAt = .now }
        activeMeetingID = nil
        isFinalizing = false
        bump()

        if let meeting = meeting(id: id) {
            let inPerson = meeting.inPerson == true
            if let snapshot = stats?.snapshot(
                inPerson: inPerson,
                speakerEngine: inPerson ? (voices > 0 ? "Live (Nemotron 3), \(voices) voice\(voices == 1 ? "" : "s") heard" : "Live model not used") : "After the meeting"
            ) {
                MeetingStore.saveDiagnostics(snapshot, for: meeting, in: settings.dataFolder)
            }
            stats = nil
            Task { await postProcess(meeting, liveActivity: liveActivity) }
        }
    }

    // MARK: Pause

    func pauseRecording() {
        guard activeMeetingID != nil, !recorder.isPaused else { return }
        recorder.pause()
        transcriber?.padSilence()
    }

    func resumeRecording() {
        guard activeMeetingID != nil else { return }
        recorder.resume()
    }

    func togglePause() {
        if recorder.isPaused { resumeRecording() } else { pauseRecording() }
    }

    // MARK: Live lines

    private func add(_ incoming: TranscriptSegment, to meeting: Meeting, in dataFolder: URL) {
        if incoming.track == .mic, liveFile.segments.contains(where: { EchoFilter.isEcho(incoming, of: $0) }) {
            return
        }
        if incoming.track == .system {
            liveFile.segments.removeAll { EchoFilter.isEcho($0, of: incoming) }
        }

        if meeting.inPerson == true, incoming.track == .mic, let tracker = speakerTracker {
            let previous = liveFile.segments.last { $0.track == .mic }.flatMap { liveVoices[$0.id] }
            if let voice = tracker.voice(start: incoming.start, end: incoming.end) ?? previous {
                liveVoices[incoming.id] = voice
            }
        }
        liveFile.segments.append(incoming)
        liveFile.segments.sort { $0.start < $1.start }
        numberLiveSpeakers()
        try? MeetingStore.saveTranscript(liveFile, for: meeting, in: dataFolder)
    }

    /// The speaker model keeps revising its view of the last few seconds. This applies those revisions
    /// to lines already on screen, except lines you moved yourself.
    private func relabelRecent(allLines: Bool = false) {
        guard let tracker = speakerTracker, let meeting = activeMeeting else { return }

        let newest = liveFile.segments.map(\.end).max() ?? 0
        let horizon = allLines ? 0 : newest - 40
        for segment in liveFile.segments where segment.track == .mic && segment.end >= horizon {
            if let voice = tracker.voice(start: segment.start, end: segment.end) {
                liveVoices[segment.id] = voice
            }
        }

        if numberLiveSpeakers() {
            try? MeetingStore.saveTranscript(liveFile, for: meeting, in: settings.dataFolder)
        }
    }

    /// Numbers the voices by the first line each one says, as the transcript does after the meeting, so the
    /// first person to talk is Speaker 1 even if the model heard a cough or a chair first. Names you gave
    /// follow the person when the numbers shift. Returns whether anything changed.
    @discardableResult
    private func numberLiveSpeakers() -> Bool {
        let voices = liveVoices.filter { !pinnedSegments.contains($0.key) }.mapValues(String.init)
        let order = liveFile.segments.filter { $0.track == .mic }.map(\.id)
        let numbers = SpeakerAssignment.numberByAppearance(voices, order: order)
        var changed = false

        var renamed: [String: String] = [:]
        for (voice, id) in numbers {
            if let slot = Int(voice), let before = liveNumbers[slot], before != id {
                renamed[before] = id
            }
        }
        if !renamed.isEmpty {
            let names = liveFile.speakerNames
            let suggested = liveFile.suggestedNames
            for before in renamed.keys {
                liveFile.speakerNames[before] = nil
                liveFile.suggestedNames[before] = nil
            }
            for (before, after) in renamed {
                liveFile.speakerNames[after] = names[before]
                liveFile.suggestedNames[after] = suggested[before]
            }
            changed = true
        }
        liveNumbers = Dictionary(uniqueKeysWithValues: numbers.compactMap { voice, id in Int(voice).map { ($0, id) } })

        for index in liveFile.segments.indices {
            let segment = liveFile.segments[index]
            guard let voice = voices[segment.id], let id = numbers[voice], segment.speakerID != id else { continue }
            liveFile.segments[index].speakerID = id
            changed = true
        }
        return changed
    }

    func addBookmark(note: String = "") {
        guard let id = activeMeetingID, recorder.isRecording else { return }
        let time = recorder.elapsed()
        update(id) { $0.bookmarks.append(Bookmark(time: time, note: note)) }
    }

    /// Ties each flag to the transcript line it was raised on. Waits for the transcript, since live text trails the audio.
    func anchorBookmarks(_ id: UUID) {
        guard let meeting = meeting(id: id), meeting.bookmarks.contains(where: { $0.segmentID == nil }) else { return }
        let file = transcript(for: meeting)
        guard !file.segments.isEmpty else { return }

        update(id) { value in
            for index in value.bookmarks.indices where value.bookmarks[index].segmentID == nil {
                guard let segment = file.segment(near: value.bookmarks[index].time) else { continue }
                value.bookmarks[index].segmentID = segment.id
                value.bookmarks[index].excerpt = segment.text
            }
        }
    }

    // MARK: - Meeting edits

    private func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index])
        try? MeetingStore.save(meetings[index], in: settings.dataFolder)
    }

    func rename(_ meeting: Meeting, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(meeting.id) { $0.title = trimmed }
    }

    func setAINotes(_ meeting: Meeting, enabled: Bool) {
        update(meeting.id) { $0.aiNotes = enabled }
    }

    func setInPerson(_ meeting: Meeting, _ inPerson: Bool) {
        update(meeting.id) { $0.inPerson = inPerson }
        mutateTranscript(meeting) { $0.mixedMic = inPerson }
    }

    /// Tells the app how many people were in the room, or nil to let it work that out. This is the strongest
    /// hint the speaker pass can have, so a finished meeting is sorted again straight away.
    func setExpectedSpeakers(_ meeting: Meeting, _ count: Int?) {
        update(meeting.id) { $0.expectedSpeakers = count }

        guard meeting.id != activeMeetingID, hasAudio(meeting), let latest = self.meeting(id: meeting.id) else { return }
        Task { await identifySpeakers(latest) }
    }

    func setNotes(_ meeting: Meeting, text: String) {
        update(meeting.id) { $0.notes = text }
    }

    func updateBookmark(_ meeting: Meeting, id: UUID, note: String) {
        update(meeting.id) { value in
            if let index = value.bookmarks.firstIndex(where: { $0.id == id }) {
                value.bookmarks[index].note = note
            }
        }
    }

    func removeBookmark(_ meeting: Meeting, id: UUID) {
        update(meeting.id) { $0.bookmarks.removeAll { $0.id == id } }
    }

    // MARK: Speaker edits

    /// Edits a transcript wherever it lives: in memory while the meeting is recording, on disk afterwards.
    private func mutateTranscript(_ meeting: Meeting, _ change: (inout TranscriptFile) -> Void) {
        if meeting.id == activeMeetingID {
            change(&liveFile)
            try? MeetingStore.saveTranscript(liveFile, for: meeting, in: settings.dataFolder)
        } else {
            var file = MeetingStore.loadTranscript(meeting, in: settings.dataFolder)
            change(&file)
            try? MeetingStore.saveTranscript(file, for: meeting, in: settings.dataFolder)
            writeMarkdown(for: meeting)
        }
        bump()
    }

    func renameSpeaker(_ meeting: Meeting, speakerID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateTranscript(meeting) { file in
            file.suggestedNames[speakerID] = nil
            if trimmed.isEmpty || trimmed == TranscriptFile.defaultName(for: speakerID) {
                file.speakerNames[speakerID] = nil
            } else {
                file.speakerNames[speakerID] = trimmed
            }
        }
    }

    /// Joins two speakers that are really one person. The kept speaker takes the other's name if it has none.
    func mergeSpeaker(_ meeting: Meeting, _ source: String, into target: String) {
        guard source != target else { return }

        mutateTranscript(meeting) { file in
            for index in file.segments.indices where file.segments[index].speakerID == source {
                file.segments[index].speakerID = target
                file.segments[index].pinned = true
                pinnedSegments.insert(file.segments[index].id)
            }
            if file.speakerNames[target] == nil, let name = file.speakerNames[source] {
                file.speakerNames[target] = name
            }
            file.speakerNames[source] = nil
            file.suggestedNames[source] = nil
        }
    }

    /// Moves lines to another speaker. Pass `nil` to start a new speaker.
    func assign(_ meeting: Meeting, segmentIDs: [UUID], to speakerID: String?) {
        let ids = Set(segmentIDs)
        mutateTranscript(meeting) { file in
            let target = speakerID ?? file.nextSpeakerID
            for index in file.segments.indices where ids.contains(file.segments[index].id) {
                file.segments[index].speakerID = target
                file.segments[index].pinned = true
            }
        }
        pinnedSegments.formUnion(ids)
    }

    func diagnostics(for meeting: Meeting) -> MeetingDiagnostics? {
        _ = revision
        return MeetingStore.loadDiagnostics(meeting, in: settings.dataFolder)
    }

    // MARK: - AI provider

    private func refreshKeyFlags() {
        hasOpenRouterKey = KeychainStore.exists(KeychainStore.openRouterAccount)
        hasCompatibleKey = KeychainStore.exists(KeychainStore.compatibleAccount)
    }

    func saveAPIKey(_ key: String, account: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account)
        } else {
            KeychainStore.save(trimmed, account: account)
        }
        refreshKeyFlags()
    }

    private var ollamaBaseURL: URL? {
        URL(string: settings.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var compatibleBaseURL: URL? {
        URL(string: settings.compatibleURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Where transcript text goes, for the privacy captions. Answers in plain words.
    var aiDestination: String {
        let local = "Transcript text stays on this Mac."
        switch settings.aiProvider {
        case .off:
            return "AI is off."
        case .appleIntelligence:
            return local
        case .ollama:
            guard let url = ollamaBaseURL, !NetworkPolicy.isLocal(url) else { return local }
            return "Transcript text, never audio, goes to your Ollama server."
        case .openAICompatible:
            guard let url = compatibleBaseURL, !NetworkPolicy.isLocal(url) else { return local }
            return "Transcript text, never audio, goes to \(url.host() ?? "your endpoint")."
        case .openRouter:
            return "Transcript text, never audio, goes to OpenRouter."
        }
    }

    /// Why AI can't run right now, or nil when it can. Offline mode is checked here so every screen agrees.
    var aiBlockReason: String? {
        let offline = settings.offlineMode
        let offlineNote = "Offline mode is on. Turn it off in Settings to use this."

        switch settings.aiProvider {
        case .off:
            return "Choose an AI provider in Settings."

        case .appleIntelligence:
            return AppleIntelligence.problem

        case .ollama:
            guard let url = ollamaBaseURL, url.host() != nil else {
                return "Enter the Ollama server address in Settings."
            }
            guard !settings.ollamaModel.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "Choose an Ollama model in Settings."
            }
            if offline, !NetworkPolicy.isLocal(url) {
                return "Offline mode only allows Ollama on this Mac."
            }
            if offline, settings.ollamaModel.contains("cloud") {
                return "Cloud models send data off this Mac. Pick a local model."
            }
            return nil

        case .openAICompatible:
            guard let url = compatibleBaseURL, url.host() != nil else {
                return "Enter the endpoint address in Settings."
            }
            guard !settings.compatibleModel.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "Choose a model in Settings."
            }
            if offline, !NetworkPolicy.isLocal(url) {
                return "Offline mode only allows endpoints on this Mac."
            }
            return nil

        case .openRouter:
            guard hasOpenRouterKey else { return "Add your OpenRouter key in Settings." }
            return offline ? "OpenRouter is a cloud service. \(offlineNote)" : nil
        }
    }

    var aiReady: Bool { aiBlockReason == nil }

    private func makeModel() -> LanguageModel? {
        guard aiReady else { return nil }

        switch settings.aiProvider {
        case .off:
            return nil

        case .appleIntelligence:
            if #available(macOS 26.0, *) {
                return AppleIntelligenceModel()
            }
            return nil

        case .ollama:
            guard let url = ollamaBaseURL else { return nil }
            return OllamaModel(
                baseURL: url,
                model: settings.ollamaModel.trimmingCharacters(in: .whitespaces),
                contextTokens: settings.ollamaContextTokens
            )

        case .openAICompatible:
            guard let url = compatibleBaseURL else { return nil }
            return OpenAICompatibleModel(
                baseURL: url,
                apiKey: KeychainStore.read(KeychainStore.compatibleAccount),
                model: settings.compatibleModel.trimmingCharacters(in: .whitespaces),
                promptBudget: 24_000,
                provider: "The endpoint"
            )

        case .openRouter:
            guard let key = KeychainStore.read(KeychainStore.openRouterAccount) else { return nil }
            let model = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return OpenAICompatibleModel(
                baseURL: AIEndpoints.openRouter,
                apiKey: key,
                model: model.isEmpty ? AppSettings.defaultModel : model,
                promptBudget: 60_000,
                provider: "OpenRouter",
                extraHeaders: ["X-Title": "Meetings"]
            )
        }
    }

    private func aiService() -> AIService? {
        makeModel().map { AIService(model: $0) }
    }

    // MARK: - Processing after a meeting

    /// Transcribes the saved audio again from scratch, replacing the current transcript and speaker labels.
    func transcribeSavedAudio(_ meeting: Meeting) async {
        await postProcess(meeting, transcribeIfMissing: true, force: true, retranscribe: true)
    }

    func identifySpeakers(_ meeting: Meeting) async {
        await postProcess(meeting, force: true, speakersOnly: true)
    }

    func generateNotes(_ meeting: Meeting) async {
        await runAI(meeting, notes: true, clean: false)
    }

    func cleanTranscript(_ meeting: Meeting) async {
        await runAI(meeting, notes: false, clean: true)
    }

    private func setStatus(_ id: UUID, _ text: String?) {
        processing[id] = text
    }

    private func postProcess(
        _ meeting: Meeting,
        transcribeIfMissing: Bool = true,
        force: Bool = false,
        speakersOnly: Bool = false,
        retranscribe: Bool = false,
        liveActivity: SpeakerActivity = SpeakerActivity()
    ) async {
        guard processing[meeting.id] == nil else { return }
        let folder = settings.dataFolder
        let id = meeting.id

        setStatus(id, "Finishing up…")
        defer {
            setStatus(id, nil)
            bump()
            applyRetention()
        }

        var file = MeetingStore.loadTranscript(meeting, in: folder)
        let inPerson = self.meeting(id: id)?.inPerson == true
        var diagnostics = MeetingStore.loadDiagnostics(meeting, in: folder) ?? MeetingDiagnostics(inPerson: inPerson)

        if file.segments.isEmpty || retranscribe, transcribeIfMissing, hasAudio(meeting),
           let asr = models.asr, let vad = models.vad {
            setStatus(id, "Transcribing the recording…")
            let offlineStats = RecordingStats()
            let segments = await OfflineTranscriber.run(
                meeting: meeting,
                dataFolder: folder,
                asr: asr,
                vad: vad,
                inPerson: inPerson,
                stats: offlineStats
            ) { fraction in
                Task { @MainActor in self.setStatus(id, "Transcribing the recording… \(Int(fraction * 100))%") }
            }
            file.segments = Self.removingEchoes(from: segments)
            file.speakerNames = [:]
            file.mixedMic = inPerson
            try? MeetingStore.saveTranscript(file, for: meeting, in: folder)

            if retranscribe {
                update(id) { value in
                    for index in value.bookmarks.indices { value.bookmarks[index].segmentID = nil }
                }
            }
            diagnostics = offlineStats.snapshot(
                inPerson: inPerson,
                speakerEngine: "",
                notes: ["Transcribed from the saved audio."]
            )
            bump()
        }

        let systemURL = existingAudio(.system, for: meeting, in: folder)
        let micURL = inPerson ? existingAudio(.mic, for: meeting, in: folder) : nil
        let missing = file.segments.contains { segment in
            let canLabel = segment.track == .system ? systemURL != nil : micURL != nil
            return canLabel && (segment.speakerID == nil || force)
        }
        let micMissing = file.segments.contains { $0.track == .mic && $0.speakerID == nil }
        let refine = inPerson && settings.refineSpeakers && micURL != nil
        let diarizeMic = micURL != nil && (refine || force || micMissing)
        let useLive = inPerson && !liveActivity.isEmpty
        let expected = self.meeting(id: id)?.expectedSpeakers

        if !file.segments.isEmpty, missing || diarizeMic || useLive {
            setStatus(id, "Separating speakers…")
            let room = diarizeMic ? await models.loadRoomModels().map { RoomModels(speakers: $0.speakers, prints: $0.prints) } : nil
            let outcome = await SpeakerLabeler.label(
                segments: file.segments,
                speakerNames: file.speakerNames,
                systemAudio: systemURL,
                micAudio: micURL,
                systemManager: systemURL == nil ? nil : models.makeDiarizer(maxSpeakers: nil),
                room: room,
                micManager: diarizeMic && room == nil ? models.makeDiarizer(maxSpeakers: 4, exactly: expected) : nil,
                diarizeMic: diarizeMic,
                liveActivity: liveActivity,
                expected: expected,
                pinned: pinnedSegments.union(file.segments.filter { $0.pinned == true }.map(\.id)),
                inPerson: inPerson,
                onProgress: { [weak self] text in
                    Task { @MainActor in self?.setStatus(id, text) }
                }
            )
            file.segments = outcome.segments
            file.speakerNames = outcome.speakerNames
            file.suggestedNames = [:]

            var pass = "after the meeting"
            if inPerson {
                if outcome.micDiarized {
                    let engine = room == nil ? "older speaker model" : "Nemotron 3"
                    pass = "refined over the whole recording (\(engine))"
                    if let expected {
                        pass += outcome.micVoices < expected
                            ? ", heard \(outcome.micVoices) of the \(expected) people you said were there"
                            : " for \(expected) people"
                    }
                    if outcome.merged > 0 {
                        pass += "; joined \(outcome.merged) voice\(outcome.merged == 1 ? "" : "s") that sounded like someone else"
                    }
                } else if useLive {
                    pass = "live voices, cut where the speaker changed"
                }
            }
            // Straight after a meeting the live engine's line is kept and extended. A later redo replaces it.
            diagnostics.speakerEngine = useLive && !diagnostics.speakerEngine.isEmpty
                ? "\(diagnostics.speakerEngine); \(pass)"
                : pass
            diagnostics.refined = outcome.micDiarized
            diagnostics.voices = inPerson ? outcome.micVoices : outcome.systemVoices
            diagnostics.speakerProblem = outcome.notes.isEmpty ? nil : outcome.notes.joined(separator: " ")
            if outcome.splits > 0 {
                diagnostics.speakerEngine += "; split \(outcome.splits) line\(outcome.splits == 1 ? "" : "s") where the speaker changed"
            }
        }

        if inPerson, !file.segments.isEmpty, settings.suggestSpeakerNames || settings.tidySpeakerChanges,
           AppleIntelligence.problem == nil, #available(macOS 26.0, *) {
            setStatus(id, "Checking speaker changes…")
            let polished = await SpeakerPolish.run(
                segments: file.segments,
                speakerNames: file.speakerNames,
                model: AppleIntelligenceModel(),
                tidy: settings.tidySpeakerChanges,
                suggest: settings.suggestSpeakerNames
            )
            file.segments = polished.segments
            file.suggestedNames = polished.suggestedNames
            if polished.moved > 0 {
                diagnostics.speakerEngine += "; Apple Intelligence moved words at \(polished.moved) speaker change\(polished.moved == 1 ? "" : "s")"
            }
        }

        file.mixedMic = inPerson
        try? MeetingStore.saveTranscript(file, for: meeting, in: folder)
        bump()

        diagnostics.generatedAt = .now
        MeetingStore.saveDiagnostics(diagnostics, for: meeting, in: folder)

        anchorBookmarks(id)

        guard !speakersOnly else {
            writeMarkdown(for: meeting)
            return
        }

        if file.segments.isEmpty, meeting.endDate.timeIntervalSince(meeting.startedAt) > 20 {
            if models.asr == nil || models.vad == nil {
                errorMessage = "The speech model isn't ready, so this meeting wasn't transcribed. Set it up in Settings, then use ⋯ › Transcribe Recording."
            } else {
                errorMessage = diagnostics.concern
                    ?? "Nothing was transcribed. Use ⋯ › Show Diagnostics to see what the microphone heard."
            }
        }

        if let latest = self.meeting(id: id), latest.aiNotes, !file.segments.isEmpty {
            await runAI(latest, notes: true, clean: true, alreadyProcessing: true)
        }
        writeMarkdown(for: meeting)
    }

    private func existingAudio(_ track: AudioTrack, for meeting: Meeting, in folder: URL) -> URL? {
        let url = MeetingStore.audioURL(track, for: meeting, in: folder)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func removingEchoes(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let system = segments.filter { $0.track == .system }
        return segments.filter { segment in
            segment.track != .mic || !system.contains { EchoFilter.isEcho(segment, of: $0) }
        }
    }

    private func runAI(_ meeting: Meeting, notes: Bool, clean: Bool, alreadyProcessing: Bool = false) async {
        guard let service = aiService() else {
            errorMessage = aiBlockReason ?? "Choose an AI provider in Settings."
            return
        }
        if !alreadyProcessing {
            guard processing[meeting.id] == nil else { return }
        }

        let folder = settings.dataFolder
        let id = meeting.id
        defer {
            if !alreadyProcessing { setStatus(id, nil) }
            bump()
        }

        var file = MeetingStore.loadTranscript(meeting, in: folder)
        guard !file.segments.isEmpty else {
            errorMessage = "This meeting has no transcript yet."
            return
        }

        do {
            if clean {
                setStatus(id, "Cleaning up the transcript…")
                let lines = file.segments.enumerated().map { index, segment in
                    (index: index, speaker: file.label(for: segment), text: segment.text)
                }
                let cleaned = try await service.clean(lines: lines)
                for index in file.segments.indices {
                    if let text = cleaned[index] {
                        file.segments[index].cleaned = text
                    }
                }
                try MeetingStore.saveTranscript(file, for: meeting, in: folder)
                bump()
            }

            if notes {
                setStatus(id, "Writing notes…")
                let current = self.meeting(id: id) ?? meeting
                let generated = try await service.makeNotes(
                    title: current.title,
                    attendees: current.attendees,
                    transcript: file.lines(useCleaned: true),
                    userNotes: current.notes,
                    bookmarks: current.bookmarks.map { bookmark in
                        var line = "\(Format.clock(bookmark.time)) \(bookmark.note)"
                        if let text = file.text(for: bookmark) { line += " — \"\(text)\"" }
                        return line
                    }
                )
                try MeetingStore.saveNotes(generated, for: current, in: folder)
            }
            writeMarkdown(for: meeting)
        } catch {
            errorMessage = "AI notes failed: \(error.localizedDescription)"
        }
    }

    func ask(_ meeting: Meeting, question: String) async throws -> String {
        guard let service = aiService() else {
            throw AIError.server(aiBlockReason ?? "Choose an AI provider in Settings.")
        }
        let file = transcript(for: meeting)
        return try await service.answer(
            question: question,
            transcript: file.lines(useCleaned: true),
            notes: notes(for: meeting)
        )
    }

    // MARK: - Export

    private func writeMarkdown(for meeting: Meeting) {
        let current = self.meeting(id: meeting.id) ?? meeting
        let markdown = MeetingMarkdown.build(
            meeting: current,
            transcript: MeetingStore.loadTranscript(current, in: settings.dataFolder),
            notes: MeetingStore.loadNotes(current, in: settings.dataFolder)
        )
        MeetingStore.writeMarkdown(markdown, for: current, in: settings.dataFolder)
    }

    func markdown(for meeting: Meeting) -> String {
        MeetingMarkdown.build(meeting: meeting, transcript: transcript(for: meeting), notes: notes(for: meeting))
    }

    func copyTranscript(_ meeting: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript(for: meeting).plainText(), forType: .string)
    }

    func exportMarkdown(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown(for: meeting).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addToReminders(_ meeting: Meeting, items: [ActionItem]) async -> String {
        do {
            let count = try await RemindersService.add(items, meetingTitle: meeting.title)
            return "Added \(count) \(count == 1 ? "reminder" : "reminders")."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Reminders for upcoming meetings

    /// Only shows the notification permission prompt when `requestIfNeeded` is true,
    /// which happens when you switch reminders on in Settings.
    func updateMeetingReminders(requestIfNeeded: Bool = false) async {
        guard !isPreview else { return }
        guard settings.meetingReminders else {
            remindersBlocked = false
            notifications.clear()
            return
        }

        var allowed = await notifications.isAuthorized()
        if !allowed, requestIfNeeded {
            allowed = await notifications.requestAuthorization()
        }
        remindersBlocked = !allowed
        if allowed {
            notifications.schedule(calendar.events)
        }
    }

    // MARK: - Search

    var searchHits: [SearchHit] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        if searchCacheRevision != revision {
            searchCache = [:]
            searchCacheRevision = revision
        }

        return meetings.compactMap { meeting in
            let text = searchableText(for: meeting)
            guard let range = text.lowercased().range(of: query) else { return nil }

            let titleMatches = meeting.title.lowercased().contains(query)
            guard !titleMatches else { return SearchHit(meeting: meeting, snippet: nil) }

            let lower = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let upper = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = text[lower..<upper].replacingOccurrences(of: "\n", with: " ")
            return SearchHit(meeting: meeting, snippet: "…\(snippet)…")
        }
    }

    private func searchableText(for meeting: Meeting) -> String {
        if let cached = searchCache[meeting.id] { return cached }

        let file = MeetingStore.loadTranscript(meeting, in: settings.dataFolder)
        var parts = [meeting.title, meeting.attendees.joined(separator: " "), meeting.notes]
        if let notes = MeetingStore.loadNotes(meeting, in: settings.dataFolder) {
            parts.append(notes.summary)
            parts.append(notes.decisions.joined(separator: " "))
            parts.append(notes.actionItems.map(\.task).joined(separator: " "))
        }
        parts.append(file.segments.map(\.displayText).joined(separator: " "))

        let text = parts.joined(separator: "\n")
        searchCache[meeting.id] = text
        return text
    }

    // MARK: - Housekeeping

    func deleteAudio(_ meeting: Meeting) {
        if playback.meetingID == meeting.id { playback.stop() }
        do {
            try MeetingStore.deleteAudio(meeting, in: settings.dataFolder)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
        bump()
    }

    func deleteMeeting(_ meeting: Meeting) {
        guard meeting.id != activeMeetingID, processing[meeting.id] == nil else { return }
        if playback.meetingID == meeting.id { playback.stop() }
        do {
            try MeetingStore.delete(meeting, in: settings.dataFolder)
        } catch {
            errorMessage = error.localizedDescription
        }
        if selection == .meeting(meeting.id) {
            selection = .upcoming
        }
        reload()
        bump()
    }

    func revealInFinder(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([
            MeetingStore.folder(for: meeting.id, in: settings.dataFolder)
        ])
    }

    func chooseDataFolder() {
        guard !recorder.isRecording else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Meetings saves recordings, transcripts, and models."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.dataFolder = url
        dataFolderChanged()
    }

    func resetDataFolder() {
        guard !recorder.isRecording else { return }
        settings.dataFolder = AppSettings.defaultFolder
        dataFolderChanged()
    }

    private func dataFolderChanged() {
        playback.stop()
        reload()
        applyRetention()
        models.configure(dataFolder: settings.dataFolder)
        bump()
    }
}

#if DEBUG
extension AppStore {
    enum PreviewScene {
        case upcoming
        case recording
        case finished
    }

    /// Sample data for SwiftUI previews. Never touches disk or user defaults.
    static func preview(_ scene: PreviewScene) -> AppStore {
        let store = AppStore(preview: true)
        let now = Date.now

        store.calendar.setPreview(events: [
            CalendarEvent(
                id: "1", title: "Design review", start: now.addingTimeInterval(8 * 60),
                end: now.addingTimeInterval(53 * 60), joinURL: URL(string: "https://zoom.us/j/123"),
                attendees: ["Maya Chen", "Jordan Ellis", "Priya Raman", "Sam Okafor", "Lena Fischer", "Tom Becker"]
            ),
            CalendarEvent(
                id: "2", title: "Weekly sync with product", start: now.addingTimeInterval(3 * 3600),
                end: now.addingTimeInterval(3.5 * 3600), joinURL: URL(string: "https://meet.google.com/abc"),
                attendees: ["Maya Chen", "Priya Raman"]
            ),
            CalendarEvent(
                id: "3", title: "1:1 with Jordan", start: now.addingTimeInterval(5 * 3600),
                end: now.addingTimeInterval(5.5 * 3600), joinURL: nil, attendees: ["Jordan Ellis"]
            ),
            CalendarEvent(
                id: "4", title: "Quarterly planning", start: now.addingTimeInterval(26 * 3600),
                end: now.addingTimeInterval(28 * 3600), joinURL: URL(string: "https://teams.microsoft.com/l/x"),
                attendees: ["Maya Chen", "Jordan Ellis", "Priya Raman", "Sam Okafor"]
            ),
        ])
        store.models.setPreviewReady()

        let current = Meeting(
            id: UUID(), title: "Design review", startedAt: now.addingTimeInterval(-754), endedAt: nil,
            joinURL: URL(string: "https://zoom.us/j/123"), attendees: ["Maya Chen", "Jordan Ellis", "Priya Raman"]
        )
        let finished = Meeting(
            id: UUID(), title: "Weekly sync with product", startedAt: now.addingTimeInterval(-26 * 3600),
            endedAt: now.addingTimeInterval(-25.4 * 3600), joinURL: nil, attendees: ["Maya Chen", "Priya Raman"]
        )
        let older = Meeting(
            id: UUID(), title: "Customer call: Northwind", startedAt: now.addingTimeInterval(-9 * 86_400),
            endedAt: now.addingTimeInterval(-9 * 86_400 + 2400), joinURL: nil, attendees: []
        )

        let segments = [
            TranscriptSegment(track: .system, start: 4, end: 12, text: "Thanks everyone for joining. Let's start with the onboarding flow, since that's where we saw the biggest drop last week.", speakerID: "S1"),
            TranscriptSegment(track: .system, start: 13, end: 22, text: "Right. The signup step is fine, but people stall on the permissions screen. About a third never get past it.", speakerID: "S1"),
            TranscriptSegment(track: .mic, start: 24, end: 31, text: "That matches what I saw in the recordings. They don't understand why we need the microphone."),
            TranscriptSegment(track: .system, start: 33, end: 44, text: "What if we show a short preview of the transcript before asking? Then the permission has an obvious payoff.", speakerID: "S2"),
            TranscriptSegment(track: .mic, start: 46, end: 50, text: "I like that. Can you mock it up by Thursday?"),
            TranscriptSegment(track: .system, start: 52, end: 58, text: "Yes, I'll have two options ready.", speakerID: "S2"),
        ]
        let names = ["S1": "Maya Chen", "S2": "Jordan Ellis"]

        switch scene {
        case .upcoming:
            store.meetings = [current, finished, older]
            store.selection = .upcoming
        case .recording:
            store.meetings = [current, finished, older]
            store.activeMeetingID = current.id
            store.liveFile = TranscriptFile(segments: segments, speakerNames: names)
            store.isTranscribingLive = true
            store.recorder.setPreviewRecording()
            store.settings.aiProvider = .openRouter
            store.hasOpenRouterKey = true
            store.selection = .meeting(current.id)
        case .finished:
            store.meetings = [finished, older]
            store.settings.aiProvider = .openRouter
            store.hasOpenRouterKey = true
            store.previewTranscript = TranscriptFile(segments: segments, speakerNames: names)
            store.previewNotes = MeetingNotes(
                summary: "The team reviewed the onboarding drop-off and traced most of it to the permissions screen, where roughly a third of new users stall. Jordan proposed showing a short transcript preview before asking for microphone access so the permission has a clear payoff. Maya agreed and asked for mockups by Thursday.",
                decisions: [
                    "Test a transcript preview ahead of the microphone permission prompt.",
                    "Keep the signup step as it is for now.",
                ],
                actionItems: [
                    ActionItem(task: "Mock up two versions of the permission preview", owner: "Jordan Ellis", due: "Thursday"),
                    ActionItem(task: "Share the session recordings with the design team", owner: "Maya Chen", due: nil),
                ],
                generatedAt: now.addingTimeInterval(-25 * 3600),
                model: "anthropic/claude-haiku-5.5"
            )
            store.selection = .meeting(finished.id)
        }
        return store
    }
}
#endif
