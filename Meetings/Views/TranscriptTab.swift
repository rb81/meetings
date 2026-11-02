import SwiftUI

private struct SpeakerGroup: Identifiable {
    let id: UUID
    let track: AudioTrack
    let speakerID: String?
    var segments: [TranscriptSegment]
}

struct TranscriptTab: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    let file: TranscriptFile
    let isLive: Bool
    let isActive: Bool
    let audioSaved: Bool

    @State private var showCleaned = true
    @State private var renamingSpeaker: String?

    private var groups: [SpeakerGroup] {
        var result: [SpeakerGroup] = []
        for segment in file.segments {
            if var last = result.last,
               last.track == segment.track,
               last.speakerID == segment.speakerID,
               segment.start - (last.segments.last?.end ?? 0) < 25 {
                last.segments.append(segment)
                result[result.count - 1] = last
            } else {
                result.append(SpeakerGroup(id: segment.id, track: segment.track, speakerID: segment.speakerID, segments: [segment]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            notice

            if audioSaved, !isActive {
                PlayerBar(meeting: meeting)
            }

            if file.segments.isEmpty {
                placeholder
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(groups) { group in
                        groupView(group)
                    }
                }
            }
        }
        .surface(padding: 24)
        .sheet(isPresented: Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )) {
            if let id = renamingSpeaker {
                NameSheet(
                    title: "Rename speaker",
                    message: "Every line from this speaker in this meeting updates.",
                    initial: file.name(for: id),
                    onSave: { name in
                        store.renameSpeaker(meeting, speakerID: id, to: name)
                        renamingSpeaker = nil
                    },
                    onCancel: { renamingSpeaker = nil }
                )
            }
        }
    }

    private var diagnostics: MeetingDiagnostics? {
        isActive ? nil : store.diagnostics(for: meeting)
    }

    private var header: some View {
        HStack(spacing: 10) {
            SectionLabel("Transcript")
            if isLive {
                Chip(text: "Live", symbol: "circle.fill", tint: Theme.red)
            }
            if meeting.inPerson == true {
                speakerCount
                if diagnostics?.refined == true {
                    Chip(text: "Refined", symbol: "checkmark", tint: Theme.green)
                        .help("A careful pass over the whole recording sorted the speakers after the meeting.")
                }
            }
            Spacer()
            if file.hasCleanedText {
                Picker("", selection: $showCleaned) {
                    Text("Cleaned").tag(true)
                    Text("Original").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 160)
            }
            if store.aiReady {
                cleanUpButton
            }
            Button {
                store.copyTranscript(meeting)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .help("Copy transcript")
            .disabled(file.segments.isEmpty)
        }
        .frame(height: 28)
    }

    /// How many people the app thinks were there, and a way to tell it. Telling it re-sorts a finished meeting.
    private var speakerCount: some View {
        let detected = file.speakerIDs.count
        let title = meeting.expectedSpeakers.map { "\($0) people" }
            ?? (detected > 0 ? "\(detected) speaker\(detected == 1 ? "" : "s")" : "Speakers")

        return Menu {
            Button((meeting.expectedSpeakers == nil ? "✓ " : "") + "Work it out automatically") {
                store.setExpectedSpeakers(meeting, nil)
            }
            ForEach(2...8, id: \.self) { count in
                Button((meeting.expectedSpeakers == count ? "✓ " : "") + "\(count) people") {
                    store.setExpectedSpeakers(meeting, count)
                }
            }
        } label: {
            Label(title, systemImage: "person.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Color.secondary.opacity(0.14), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.processing[meeting.id] != nil)
        .help(isActive
              ? "Say how many people are in the room. It's used to sort the speakers when the meeting ends."
              : "Say how many people were in the room. The speakers are sorted again using that number.")
    }

    @ViewBuilder
    private var notice: some View {
        if meeting.inPerson == true {
            if isActive, isLive, !store.liveSpeakersActive {
                HStack(alignment: .top, spacing: 10) {
                    noticeBox(store.models.hasRoomModels
                              ? "Voices can't be told apart while you record, because the live speaker model couldn't be loaded. They'll be sorted when the meeting ends."
                              : "Voices can't be told apart while you record, because the in-person speaker models aren't downloaded. The download applies from the next meeting.")
                    if store.models.missingSpeakerModels != nil {
                        downloadButton
                    }
                }
            } else if !isActive, let problem = diagnostics?.speakerProblem {
                HStack(alignment: .top, spacing: 10) {
                    noticeBox("Speakers weren't fully sorted: \(problem)")
                    if store.models.missingSpeakerModels != nil {
                        downloadButton
                    } else {
                        Button("Try Again") {
                            Task { await store.identifySpeakers(meeting) }
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 28))
                        .disabled(store.processing[meeting.id] != nil)
                    }
                }
            } else if !isActive, file.segments.contains(where: { $0.track == .mic && $0.speakerID == nil }) {
                HStack(alignment: .top, spacing: 10) {
                    noticeBox(!store.models.hasRoomModels
                              ? "Speakers couldn't be told apart because the in-person speaker models aren't downloaded."
                              : "Speakers couldn't be told apart in this recording. Try again, or use ⋯ › Show Diagnostics to see what the microphone heard.")
                    if !store.models.hasRoomModels {
                        downloadButton
                    } else {
                        Button("Try Again") {
                            Task { await store.identifySpeakers(meeting) }
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 28))
                        .disabled(store.processing[meeting.id] != nil)
                    }
                }
            }
        }
    }

    private var downloadButton: some View {
        var busy = store.models.isDownloadingRoomModels
        if case .working = store.models.state { busy = true }

        return Button(busy ? "Downloading…" : "Download") {
            store.models.downloadMissingSpeakerModels()
        }
        .buttonStyle(SecondaryButtonStyle(height: 28))
        .disabled(busy)
    }

    private func noticeBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.amber)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Theme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }

    private var cleanUpButton: some View {
        let busy = store.processing[meeting.id] != nil

        return Button {
            Task { await store.cleanTranscript(meeting) }
        } label: {
            Label(file.hasCleanedText ? "Clean Up Again" : "Clean Up", systemImage: "sparkles")
        }
        .buttonStyle(SecondaryButtonStyle(height: 28))
        .disabled(file.segments.isEmpty || isActive || busy)
        .help("Fix punctuation and obvious mistakes with your AI provider. Flags stay on their lines.")
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: isLive ? "waveform" : "text.alignleft")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text(placeholderText)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var placeholderText: String {
        if isLive { return "Listening… text appears a moment after people speak." }
        if store.processing[meeting.id] != nil { return "Working on the transcript…" }
        if audioSaved { return "No transcript yet. Use ⋯ › Transcribe Recording." }
        return "No transcript for this meeting."
    }

    private func groupView(_ group: SpeakerGroup) -> some View {
        let first = group.segments[0]
        let name = file.label(for: first)
        let color = Palette.color(for: first)

        return HStack(alignment: .top, spacing: 14) {
            Avatar(name: name, color: color, size: 32)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    speakerName(name, color: color, group: group)
                    Text(Format.clock(first.start))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(height: 18)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.segments) { segment in
                        Text(showCleaned ? segment.displayText : segment.text)
                            .font(Theme.body)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard audioSaved, !isActive else { return }
                                store.playback.load(meeting, dataFolder: store.settings.dataFolder)
                                store.playback.play(from: segment.start)
                            }
                            .contextMenu {
                                Button("Copy Line") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(segment.displayText, forType: .string)
                                }
                                moveMenu("Move Line To…", ids: [segment.id], excluding: segment.speakerID)
                                if audioSaved, !isActive {
                                    Button("Play From Here") {
                                        store.playback.load(meeting, dataFolder: store.settings.dataFolder)
                                        store.playback.play(from: segment.start)
                                    }
                                }
                            }
                            .help(audioSaved && !isActive ? "Click to play from here" : "")
                    }
                }
            }
        }
    }

    private func speakerName(_ name: String, color: Color, group: SpeakerGroup) -> some View {
        Menu {
            if let id = group.speakerID {
                let used = Set(file.speakerNames.values)
                if file.speakerNames[id] == nil, let suggested = file.suggestedNames[id], !used.contains(suggested) {
                    Button("Use \u{201C}\(suggested)\u{201D} (heard in the meeting)") {
                        store.renameSpeaker(meeting, speakerID: id, to: suggested)
                    }
                    Divider()
                }
                ForEach(meeting.attendees.filter { !used.contains($0) }, id: \.self) { attendee in
                    Button(attendee) { store.renameSpeaker(meeting, speakerID: id, to: attendee) }
                }
                if !meeting.attendees.isEmpty { Divider() }
                Button("Rename…") {
                    renamingSpeaker = id
                }

                let others = file.speakerIDs.filter { $0 != id }
                if !others.isEmpty {
                    Menu("Merge Into…") {
                        ForEach(others, id: \.self) { other in
                            Button(file.name(for: other)) { store.mergeSpeaker(meeting, id, into: other) }
                        }
                    }
                }
                Divider()
            }
            moveMenu("Move This Block To…", ids: group.segments.map(\.id), excluding: group.speakerID)
        } label: {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rename, merge, or move this speaker's lines")
    }

    private func moveMenu(_ title: String, ids: [UUID], excluding current: String?) -> some View {
        Menu(title) {
            ForEach(file.speakerIDs.filter { $0 != current }, id: \.self) { target in
                Button(file.name(for: target)) { store.assign(meeting, segmentIDs: ids, to: target) }
            }
            Button("New Speaker") { store.assign(meeting, segmentIDs: ids, to: nil) }
        }
    }
}

struct PlayerBar: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting

    var body: some View {
        let playback = store.playback

        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: 14) {
                Button {
                    if playback.isPlaying { playback.pause() } else { playback.play() }
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Theme.brand, in: Circle())
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { min(playback.currentTime, max(playback.duration, 1)) },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 1)
                )
                .tint(Theme.blue)

                Text("\(Format.clock(playback.currentTime)) / \(Format.clock(playback.duration))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        }
        .onAppear {
            playback.load(meeting, dataFolder: store.settings.dataFolder)
        }
    }
}
