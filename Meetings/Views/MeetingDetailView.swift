import AppKit
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case summary
    case transcript
    case notes
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: "Summary"
        case .transcript: "Transcript"
        case .notes: "Notes"
        case .ask: "Ask"
        }
    }

    var symbol: String {
        switch self {
        case .summary: "sparkles"
        case .transcript: "text.alignleft"
        case .notes: "flag"
        case .ask: "bubble.left.and.text.bubble.right"
        }
    }
}

struct MeetingDetailView: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting

    @State private var tab: DetailTab = .transcript
    @State private var title = ""
    @State private var saved = TranscriptFile()
    @State private var notes: MeetingNotes?
    @State private var confirmDelete = false
    @State private var showDiagnostics = false
    @State private var diagnostics: MeetingDiagnostics?
    @State private var selection: Set<UUID> = []
    @State private var confirmRemoveSelection = false

    private var diagnosticsText: String {
        diagnostics?.text
            ?? "No diagnostics were saved for this meeting. They're recorded for meetings made with this version of the app."
    }

    private var isActive: Bool { meeting.id == store.activeMeetingID }
    private var file: TranscriptFile { isActive ? store.liveFile : saved }
    private var audioSaved: Bool { store.hasAudio(meeting) }
    private var isBusy: Bool { store.isBusy(meeting.id) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                titleRow
                TabBar(
                    tabs: DetailTab.allCases,
                    selection: $tab,
                    title: \.title,
                    symbol: \.symbol
                )
            }
            .padding(.horizontal, Theme.pad)
            .padding(.top, Theme.pad)

            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        content
                        Color.clear.frame(height: tab == .transcript ? 48 : 1).id("bottom")
                    }
                    .padding(Theme.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
                .onChange(of: store.liveFile.segments.count) {
                    // Only follow new lines when nothing is selected, so the view doesn't jump while you edit.
                    guard isActive, tab == .transcript, selection.isEmpty else { return }
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .overlay(alignment: .bottom) {
                if tab == .transcript {
                    TranscriptActionBar(
                        meeting: meeting,
                        file: file,
                        selection: $selection,
                        confirmRemove: $confirmRemoveSelection
                    )
                    .padding(.bottom, 16)
                }
            }
        }
        .task(id: meeting.id) {
            title = meeting.title
            selection = []
            tab = isActive ? .transcript : (store.notes(for: meeting) != nil ? .summary : .transcript)
        }
        .task(id: "\(meeting.id)|\(store.revision)|\(isActive)") {
            if !isActive {
                saved = store.transcript(for: meeting)
            }
            notes = store.notes(for: meeting)
            diagnostics = isActive ? nil : store.diagnostics(for: meeting)
            // Lines removed elsewhere can't stay selected.
            let present = Set(file.segments.map(\.id))
            if !selection.isSubset(of: present) { selection.formIntersection(present) }
        }
        .onExitCommand {
            if !selection.isEmpty { selection = [] }
        }
        .confirmationDialog(
            "Remove \(selection.count) selected line\(selection.count == 1 ? "" : "s")?",
            isPresented: $confirmRemoveSelection,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                store.removeSegments(meeting, ids: selection)
                selection = []
            }
        } message: {
            Text("You can undo this from the bar at the bottom of the window.")
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteMeeting(meeting)
            }
        } message: {
            Text("The audio, transcript, and notes for this meeting will be removed from your data folder.")
        }
        .alert("Recording diagnostics", isPresented: $showDiagnostics) {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(diagnosticsText, forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticsText)
        }
    }

    // MARK: Header

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(Theme.title)
                    .onSubmit { store.rename(meeting, to: title) }

                subtitleRow
            }

            Spacer(minLength: 0)

            actions
        }
    }

    private var subtitleRow: some View {
        HStack(spacing: 10) {
            Text(subtitle)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if meeting.inPerson == true {
                Chip(text: "In person", symbol: "person.2.fill", tint: Theme.blue)
            }

            if isActive {
                let paused = store.recorder.isPaused
                Chip(text: paused ? "Paused" : "Recording", symbol: "circle.fill", tint: paused ? Theme.amber : Theme.red)
            } else if isBusy {
                ProcessingStatusChip(meetingID: meeting.id)
            }
        }
    }

    private var subtitle: String {
        if isActive { return "Started \(Format.time(meeting.startedAt))" }
        var text = "\(Format.day(meeting.startedAt)) · \(Format.range(meeting.startedAt, meeting.endDate))"
        if !meeting.attendees.isEmpty {
            text += " · \(meeting.attendees.count) \(meeting.attendees.count == 1 ? "guest" : "guests")"
        }
        return text
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if let url = meeting.joinURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "video")
                }
                .buttonStyle(IconButtonStyle())
                .help("Open the meeting link")
            }

            Menu {
                Button("Show in Finder") { store.revealInFinder(meeting) }
                Divider()
                Button("Export as Markdown…") { store.exportMarkdown(meeting) }
                Button("Copy Transcript") { store.copyTranscript(meeting) }
                    .disabled(file.segments.isEmpty)
                if audioSaved, !isActive {
                    Divider()
                    Button(file.segments.isEmpty ? "Transcribe Recording" : "Transcribe Again") {
                        Task { await store.transcribeSavedAudio(meeting) }
                    }
                    .disabled(!store.models.isReady || isBusy)
                    Toggle("In-person meeting", isOn: Binding(
                        get: { meeting.inPerson == true },
                        set: { store.setInPerson(meeting, $0) }
                    ))
                    Button("Identify Speakers Again") {
                        Task { await store.identifySpeakers(meeting) }
                    }
                    .disabled((meeting.inPerson == true ? !store.models.hasRoomModels && store.models.diarizer == nil : store.models.diarizer == nil)
                              || file.segments.isEmpty || isBusy)
                    Button("Delete Audio", role: .destructive) {
                        store.deleteAudio(meeting)
                    }
                }
                if !isActive {
                    Divider()
                    Button("Show Diagnostics…") { showDiagnostics = true }
                }
                Divider()
                Button("Delete Meeting…", role: .destructive) {
                    confirmDelete = true
                }
                .disabled(isActive || isBusy)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .summary:
            SummaryTab(meeting: meeting, notes: notes, file: file)
        case .transcript:
            TranscriptTab(
                meeting: meeting,
                file: file,
                isLive: isActive && store.isTranscribingLive,
                isActive: isActive,
                audioSaved: audioSaved,
                diagnostics: diagnostics,
                selection: $selection
            )
        case .notes:
            NotesTab(meeting: meeting, file: file, isActive: isActive, audioSaved: audioSaved)
        case .ask:
            AskTab(meeting: meeting, file: file)
        }
    }
}

/// What's happening to a meeting after recording, with a bar when the step's progress is known.
/// Kept separate so progress ticks only redraw this chip, not the transcript.
private struct ProcessingStatusChip: View {
    @Environment(AppStore.self) private var store
    let meetingID: UUID

    var body: some View {
        let status = store.processing[meetingID] ?? "Working…"
        let progress = store.processingProgress[meetingID]

        HStack(spacing: 8) {
            if progress == nil {
                ProgressView().controlSize(.mini)
            }
            Text(status)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.blue)
                    .frame(width: 80)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 30, alignment: .trailing)
            }
        }
        .foregroundStyle(Theme.blue)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Theme.blue.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Floats over the transcript: actions for the selected lines, or a way to undo the last bulk change.
private struct TranscriptActionBar: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    let file: TranscriptFile
    @Binding var selection: Set<UUID>
    @Binding var confirmRemove: Bool

    var body: some View {
        if !selection.isEmpty {
            bar {
                Text("\(selection.count) line\(selection.count == 1 ? "" : "s") selected")
                    .font(.system(size: 12, weight: .semibold))
                Menu("Move To…") {
                    ForEach(file.speakerIDs, id: \.self) { target in
                        Button(file.name(for: target)) { move(to: target) }
                    }
                    Button("New Speaker") { move(to: nil) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Remove…") { confirmRemove = true }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                Button {
                    selection = []
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("Clear the selection (Esc)")
                .accessibilityLabel("Clear selection")
            }
        } else if let edit = store.lastEdit, edit.meetingID == meeting.id {
            bar {
                Text(edit.message)
                    .font(.system(size: 12, weight: .semibold))
                Button("Undo") { store.undoLastEdit() }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                    .disabled(store.isBusy(meeting.id))
                Button {
                    store.dismissLastEdit()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
    }

    private func move(to target: String?) {
        let ordered = file.segments.map(\.id).filter(selection.contains)
        store.assign(meeting, segmentIDs: ordered, to: target)
        selection = []
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
