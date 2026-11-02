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

    private var diagnosticsText: String {
        store.diagnostics(for: meeting)?.text
            ?? "No diagnostics were saved for this meeting. They're recorded for meetings made with this version of the app."
    }

    private var isActive: Bool { meeting.id == store.activeMeetingID }
    private var file: TranscriptFile { isActive ? store.liveFile : saved }
    private var audioSaved: Bool { store.hasAudio(meeting) }
    private var status: String? { store.processing[meeting.id] }

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
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(Theme.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .onChange(of: store.liveFile.segments.count) {
                    guard isActive, tab == .transcript else { return }
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .task(id: meeting.id) {
            title = meeting.title
            tab = isActive ? .transcript : (store.notes(for: meeting) != nil ? .summary : .transcript)
        }
        .task(id: "\(meeting.id)|\(store.revision)|\(isActive)") {
            if !isActive {
                saved = store.transcript(for: meeting)
            }
            notes = store.notes(for: meeting)
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
            } else if let status {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.blue)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Theme.blue.opacity(0.14), in: Capsule())
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
                    .disabled(!store.models.isReady || status != nil)
                    Toggle("In-person meeting", isOn: Binding(
                        get: { meeting.inPerson == true },
                        set: { store.setInPerson(meeting, $0) }
                    ))
                    Button("Identify Speakers Again") {
                        Task { await store.identifySpeakers(meeting) }
                    }
                    .disabled((meeting.inPerson == true ? !store.models.hasRoomModels && store.models.diarizer == nil : store.models.diarizer == nil)
                              || file.segments.isEmpty || status != nil)
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
                .disabled(isActive || status != nil)
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
                audioSaved: audioSaved
            )
        case .notes:
            NotesTab(meeting: meeting, file: file, isActive: isActive, audioSaved: audioSaved)
        case .ask:
            AskTab(meeting: meeting, file: file)
        }
    }
}
