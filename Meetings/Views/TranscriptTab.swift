import AppKit
import SwiftUI

private struct SpeakerGroup: Identifiable {
    let id: UUID
    let track: AudioTrack
    let speakerID: String?
    var segments: [TranscriptSegment]
}

/// Lines waiting for you to confirm they should be removed.
private struct PendingRemoval: Identifiable {
    let id = UUID()
    let title: String
    let ids: Set<UUID>
}

struct TranscriptTab: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    let file: TranscriptFile
    let isLive: Bool
    let isActive: Bool
    let audioSaved: Bool
    let diagnostics: MeetingDiagnostics?
    /// The lines picked with ⌘-click or ⇧-click, acted on from the bar at the bottom of the window.
    @Binding var selection: Set<UUID>

    @State private var showCleaned = true
    @State private var renamingSpeaker: String?
    @State private var selectionAnchor: UUID?
    @State private var pendingRemoval: PendingRemoval?

    /// Runs of lines from the same speaker. Built once per update, because long meetings have thousands of lines.
    private static func groups(for segments: [TranscriptSegment]) -> [SpeakerGroup] {
        var result: [SpeakerGroup] = []
        for segment in segments {
            if var last = result.last,
               last.speakerID == segment.speakerID,
               segment.speakerID != nil || last.track == segment.track,
               segment.start - (last.segments.last?.end ?? 0) < 25 {
                last.segments.append(segment)
                result[result.count - 1] = last
            } else {
                result.append(SpeakerGroup(id: segment.id, track: segment.track, speakerID: segment.speakerID, segments: [segment]))
            }
        }
        return result
    }

    private var isBusy: Bool { store.isBusy(meeting.id) }

    var body: some View {
        let speakerIDs = file.speakerIDs

        VStack(alignment: .leading, spacing: 20) {
            header(speakerIDs: speakerIDs)

            notice

            if audioSaved, !isActive {
                PlayerBar(meeting: meeting)
            }

            if file.segments.isEmpty {
                placeholder
            } else {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Self.groups(for: file.segments)) { group in
                        groupView(group, speakerIDs: speakerIDs)
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
        .confirmationDialog(
            pendingRemoval?.title ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            Button("Remove \(removal.ids.count) Line\(removal.ids.count == 1 ? "" : "s")", role: .destructive) {
                store.removeSegments(meeting, ids: removal.ids)
                selection.subtract(removal.ids)
            }
        } message: { _ in
            Text("You can undo this from the bar at the bottom of the window.")
        }
    }

    private func header(speakerIDs: [String]) -> some View {
        HStack(spacing: 10) {
            SectionLabel("Transcript")
            if isLive {
                Chip(text: "Live", symbol: "circle.fill", tint: Theme.red)
            }
            speakerCount
            if meeting.inPerson == true, diagnostics?.refined == true {
                Chip(text: "Refined", symbol: "checkmark", tint: Theme.green)
                    .help("A careful pass over the whole recording sorted the speakers after the meeting.")
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

    /// How many people the app thinks there were, and a way to tell it. Telling it re-sorts a finished meeting.
    /// In person that's everyone in the room; online it's the people on the call, not counting you.
    private var speakerCount: some View {
        let inPerson = meeting.inPerson == true
        let track: AudioTrack = inPerson ? .mic : .system
        let detected = Set(file.segments.lazy.filter { $0.track == track }.compactMap(\.speakerID)).count
        let noun = inPerson ? "people" : "on the call"
        let title = meeting.expectedSpeakers.map { inPerson ? "\($0) people" : "\($0) on the call" }
            ?? (detected > 0 ? (inPerson ? "\(detected) speaker\(detected == 1 ? "" : "s")" : "\(detected) on the call") : "Speakers")

        return Menu {
            Button((meeting.expectedSpeakers == nil ? "✓ " : "") + "Work it out automatically") {
                store.setExpectedSpeakers(meeting, nil)
            }
            ForEach(Array(inPerson ? 2...8 : 1...8), id: \.self) { count in
                let label = inPerson ? "\(count) people" : "\(count) \(count == 1 ? "person" : "people") \(noun)"
                Button((meeting.expectedSpeakers == count ? "✓ " : "") + label) {
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
        .disabled(isBusy)
        .help(speakerCountHelp(inPerson: inPerson))
    }

    private func speakerCountHelp(inPerson: Bool) -> String {
        switch (inPerson, isActive) {
        case (true, true): "Say how many people are in the room. It's used to sort the speakers when the meeting ends."
        case (true, false): "Say how many people were in the room. The speakers are sorted again using that number."
        case (false, true): "Say how many people are on the call, not counting you. It's used to sort the speakers when the meeting ends."
        case (false, false): "Say how many people were on the call, not counting you. The speakers are sorted again using that number."
        }
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
                        tryAgainButton
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
                        tryAgainButton
                    }
                }
            }
        } else if isActive, store.micBleedWarning {
            HStack(alignment: .top, spacing: 10) {
                noticeBox("Your microphone is picking up the call from your speakers. Those lines are being left out, but some of what you say may be too. If you're only listening, mute yourself; otherwise headphones work best.")
                Button("Mute Me") { store.toggleMute() }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                Button("Dismiss") { store.dismissBleedWarning() }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
            }
        } else if !isActive, let removed = diagnostics?.echoLinesRemoved, removed > 0 {
            noticeBox(
                "\(removed) microphone line\(removed == 1 ? " was" : "s were") the call playing through your speakers, so \(removed == 1 ? "it was" : "they were") left out.",
                symbol: "info.circle.fill",
                tint: Theme.blue
            )
        }
    }

    private var tryAgainButton: some View {
        Button("Try Again") {
            Task { await store.identifySpeakers(meeting) }
        }
        .buttonStyle(SecondaryButtonStyle(height: 28))
        .disabled(isBusy)
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

    private func noticeBox(_ text: String, symbol: String = "exclamationmark.triangle.fill", tint: Color = Theme.amber) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }

    private var cleanUpButton: some View {
        Button {
            Task { await store.cleanTranscript(meeting) }
        } label: {
            Label(file.hasCleanedText ? "Clean Up Again" : "Clean Up", systemImage: "sparkles")
        }
        .buttonStyle(SecondaryButtonStyle(height: 28))
        .disabled(file.segments.isEmpty || isActive || isBusy)
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
        if isBusy { return "Working on the transcript…" }
        if audioSaved { return "No transcript yet. Use ⋯ › Transcribe Recording." }
        return "No transcript for this meeting."
    }

    // MARK: - Lines

    private func groupView(_ group: SpeakerGroup, speakerIDs: [String]) -> some View {
        let first = group.segments[0]
        let name = file.label(for: first)
        let color = Palette.color(for: first)
        let blockSelected = group.segments.allSatisfy { selection.contains($0.id) }

        return HStack(alignment: .top, spacing: 14) {
            Avatar(name: name, color: color, size: 32)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    speakerName(name, color: color, group: group, speakerIDs: speakerIDs)
                    Text(Format.clock(first.start))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(height: 18)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.segments) { segment in
                        line(segment, in: group, speakerIDs: speakerIDs)
                    }
                }
            }
        }
        .padding(blockSelected ? 6 : 0)
        .background(
            blockSelected ? Theme.blue.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        )
    }

    private func line(_ segment: TranscriptSegment, in group: SpeakerGroup, speakerIDs: [String]) -> some View {
        let selected = selection.contains(segment.id)
        let canPlay = audioSaved && !isActive

        return Text(showCleaned ? segment.displayText : segment.text)
            .font(Theme.body)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, selected ? 6 : 0)
            .background(
                selected ? Theme.blue.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .contentShape(Rectangle())
            .onTapGesture { click(segment) }
            .contextMenu {
                Button("Copy Line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(segment.displayText, forType: .string)
                }
                if canPlay {
                    Button("Play From Here") { play(segment) }
                }
                Divider()
                moveMenu("Move Line To…", ids: [segment.id], excluding: segment.speakerID, speakerIDs: speakerIDs)
                Button("Select Block") { select(group.segments.map(\.id)) }
                Button("Remove Line") { store.removeSegments(meeting, ids: [segment.id]) }
            }
            .help(canPlay ? "Click to play from here. ⌘-click or ⇧-click to select lines." : "⌘-click or ⇧-click to select lines.")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A plain click plays from the line. ⌘-click picks single lines and ⇧-click picks everything in between,
    /// like a Finder list.
    private func click(_ segment: TranscriptSegment) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let from = file.segments.firstIndex(where: { $0.id == anchor }),
           let to = file.segments.firstIndex(where: { $0.id == segment.id }) {
            selection.formUnion(file.segments[min(from, to)...max(from, to)].map(\.id))
        } else if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selection.contains(segment.id) { selection.remove(segment.id) } else { selection.insert(segment.id) }
            selectionAnchor = segment.id
        } else {
            if !selection.isEmpty {
                selection = []
                return
            }
            guard audioSaved, !isActive else { return }
            play(segment)
        }
    }

    private func play(_ segment: TranscriptSegment) {
        store.playback.load(meeting, dataFolder: store.settings.dataFolder)
        store.playback.play(from: segment.start)
    }

    private func select(_ ids: [UUID]) {
        selection.formUnion(ids)
        selectionAnchor = ids.last
    }

    /// Lines that read as the same speaker as `segment`: the same voice, or for unsorted lines, the same side of
    /// the call.
    private func sameSpeaker(as segment: TranscriptSegment) -> (TranscriptSegment) -> Bool {
        if let id = segment.speakerID { return { $0.speakerID == id } }
        return { $0.speakerID == nil && $0.track == segment.track }
    }

    // MARK: - Speaker menu

    private func speakerName(_ name: String, color: Color, group: SpeakerGroup, speakerIDs: [String]) -> some View {
        Menu {
            speakerMenu(name, group: group, speakerIDs: speakerIDs)
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

    @ViewBuilder
    private func speakerMenu(_ name: String, group: SpeakerGroup, speakerIDs: [String]) -> some View {
        let first = group.segments[0]
        let matches = sameSpeaker(as: first)
        let blockIDs = group.segments.map(\.id)
        let fromHere = file.segments.filter { $0.start >= first.start && matches($0) }.map(\.id)
        let everyLine = file.segments.filter(matches).map(\.id)

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

            let others = speakerIDs.filter { $0 != id }
            if !others.isEmpty {
                Menu("Merge Into…") {
                    ForEach(others, id: \.self) { other in
                        Button(file.name(for: other)) { store.mergeSpeaker(meeting, id, into: other) }
                    }
                }
            }
            Divider()
        }
        moveMenu("Move This Block To…", ids: blockIDs, excluding: group.speakerID, speakerIDs: speakerIDs)
        if fromHere.count > blockIDs.count {
            moveMenu("Move This and Later \(name) Lines To…", ids: fromHere, excluding: group.speakerID, speakerIDs: speakerIDs)
        }
        if group.speakerID == nil, everyLine.count > blockIDs.count {
            moveMenu("Move All \(name) Lines To…", ids: everyLine, excluding: nil, speakerIDs: speakerIDs)
        }
        Divider()
        Button("Select This Block") { select(blockIDs) }
        Button("Select All \(name) Lines") { select(everyLine) }
        Divider()
        Button("Remove This Block…") {
            pendingRemoval = PendingRemoval(title: "Remove this block from the transcript?", ids: Set(blockIDs))
        }
        if everyLine.count > blockIDs.count {
            Button("Remove All \(name) Lines…") {
                pendingRemoval = PendingRemoval(title: "Remove every line from \(name)?", ids: Set(everyLine))
            }
        }
    }

    private func moveMenu(_ title: String, ids: [UUID], excluding current: String?, speakerIDs: [String]) -> some View {
        Menu(title) {
            ForEach(speakerIDs.filter { $0 != current }, id: \.self) { target in
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
