import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: Theme.sidebarWidth)

            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 1)

            contentPane
        }
        .frame(
            minWidth: Theme.windowSize.width, maxWidth: Theme.windowSize.width,
            minHeight: Theme.windowSize.height, maxHeight: .infinity
        )
        .background(Theme.canvas)
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "Download the in-person speaker models?",
            isPresented: Binding(
                get: { store.speakerModelPrompt != nil },
                set: { if !$0 { store.resolveSpeakerModelPrompt(.cancel) } }
            ),
            titleVisibility: .visible
        ) {
            Button("Download and Start") { store.resolveSpeakerModelPrompt(.download) }
            Button("Start Without Them") { store.resolveSpeakerModelPrompt(.startWithout) }
            Button("Cancel", role: .cancel) { store.resolveSpeakerModelPrompt(.cancel) }
        } message: {
            Text("They tell the voices in the room apart. It's a one-time download of about 430 MB, and your meeting starts as soon as it finishes. Without them, everything said in the room is labelled \"Room\".")
        }
        .sheet(isPresented: Binding(
            get: { store.waitingToStart != nil },
            set: { if !$0 { store.cancelWaitingMeeting() } }
        )) {
            SpeakerModelDownloadSheet()
                .environment(store)
        }
        .task { await store.updateMeetingReminders() }
        .onChange(of: store.calendar.events) {
            Task { await store.updateMeetingReminders() }
        }
        .onChange(of: store.settings.meetingReminders) {
            Task { await store.updateMeetingReminders(requestIfNeeded: true) }
        }
    }

    private var contentPane: some View {
        ZStack(alignment: .top) {
            Theme.canvas
            RadialGradient(
                colors: [Theme.blue.opacity(0.10), Theme.violet.opacity(0.04), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 560
            )
            .allowsHitTesting(false)

            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let version = store.updates.availableVersion {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Theme.blue)
                    Text("Meetings \(version) is available.")
                        .font(Theme.body)
                    Spacer()
                    Link("View Release", destination: UpdateService.releasesURL)
                    Button("Dismiss") { store.updates.dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Theme.surface)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.recorder.isRecording {
                RecordingBar()
                    .padding(.horizontal, Theme.pad)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selection {
        case .meeting(let id)?:
            if let meeting = store.meeting(id: id) {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
            } else {
                UpcomingView()
            }
        case .upcoming?, nil:
            UpcomingView()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    private var groups: [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        var buckets: [String: [Meeting]] = [:]
        for meeting in store.meetings {
            let date = meeting.startedAt
            let key: String
            if calendar.isDateInToday(date) {
                key = "Today"
            } else if calendar.isDateInYesterday(date) {
                key = "Yesterday"
            } else if calendar.isDate(date, equalTo: .now, toGranularity: .weekOfYear) {
                key = "This week"
            } else {
                key = "Earlier"
            }
            buckets[key, default: []].append(meeting)
        }
        return ["Today", "Yesterday", "This week", "Earlier"].compactMap { title in
            buckets[title].map { (title, $0) }
        }
    }

    private var isSearching: Bool {
        !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 20)
                .padding(.top, 50)

            recordButton
                .padding(.horizontal, 16)
                .padding(.top, 20)

            upcomingRow
                .padding(.horizontal, 10)
                .padding(.top, 18)

            searchField
                .padding(.horizontal, 16)
                .padding(.top, 12)

            meetingList

            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }

    private var brand: some View {
        Text("Meetings")
            .font(.system(size: 20, weight: .semibold, design: .rounded))
    }

    @ViewBuilder
    private var recordButton: some View {
        if store.recorder.isRecording {
            let paused = store.recorder.isPaused
            let tint = paused ? Theme.amber : Theme.red

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(paused ? "Paused" : "Recording…")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(tint.opacity(0.35))
                )

                HStack(spacing: 8) {
                    Button {
                        store.togglePause()
                    } label: {
                        Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 34))
                    .help(paused ? "Resume recording (⇧⌘P)" : "Pause recording (⇧⌘P)")

                    Button {
                        Task { await store.stopRecording() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 34, tint: Theme.red))
                    .help("Stop and save the meeting (⌘.)")
                }
                .disabled(store.isFinalizing)
            }
        } else {
            VStack(spacing: 8) {
                Button {
                    Task { await store.startQuickRecording() }
                } label: {
                    Label("Start Online Meeting", systemImage: "video.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(height: 40))
                .keyboardShortcut("r", modifiers: .command)
                .help("Start an online meeting (⌘R)")

                Button {
                    Task { await store.startQuickRecording(inPerson: true) }
                } label: {
                    Label("Start In-Person Meeting", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 40))
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Start a meeting in the room (⇧⌘R)")
            }
        }
    }

    private var upcomingRow: some View {
        let selected = store.selection == .upcoming || store.selection == nil
        let count = store.calendar.events.filter { Calendar.current.isDateInToday($0.start) }.count

        return Button {
            store.selection = .upcoming
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.blue : .secondary)
                Text("Upcoming")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Theme.raised, in: Capsule())
                }
            }
            .frame(height: 36)
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
    }

    private var searchField: some View {
        @Bindable var store = store

        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search meetings", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.stroke)
        )
    }

    private var meetingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if isSearching {
                    header("Results")
                    let hits = store.searchHits
                    if hits.isEmpty {
                        Text("No matches")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    ForEach(hits) { hit in
                        MeetingRow(meeting: hit.meeting, snippet: hit.snippet)
                    }
                } else if store.meetings.isEmpty {
                    header("Recorded")
                    Text("Your meetings will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    ForEach(groups, id: \.title) { group in
                        header(group.title)
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }

    private func header(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 12) {
                SettingsLink {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                        Text("Settings")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if store.settings.offlineMode {
                    Label("Offline", systemImage: "wifi.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.green)
                        .help("Offline mode is on. Nothing leaves this Mac except the speech model download.")
                }

                HStack(spacing: 6) {
                    Circle().fill(modelStatus.color).frame(width: 7, height: 7)
                    Text(modelStatus.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
        }
    }

    private var modelStatus: (text: String, color: Color) {
        switch store.models.state {
        case .ready: ("Model ready", Theme.green)
        case .loading: ("Loading model…", Theme.amber)
        case .working: ("Downloading…", Theme.blue)
        case .notDownloaded: ("Model not set up", .secondary)
        case .failed: ("Needs repair", Theme.red)
        }
    }
}

struct MeetingRow: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    var snippet: String?

    private var selected: Bool { store.selection == .meeting(meeting.id) }

    var body: some View {
        Button {
            store.selection = .meeting(meeting.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    if let snippet {
                        Text(snippet)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(Format.dayTime(meeting.startedAt))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if meeting.id == store.activeMeetingID {
                    Circle().fill(Theme.red).frame(width: 8, height: 8)
                } else if store.processing[meeting.id] != nil {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.vertical, 8)
            .frame(minHeight: 52)
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .contextMenu {
            Button("Delete Meeting", role: .destructive) {
                store.deleteMeeting(meeting)
            }
            .disabled(meeting.id == store.activeMeetingID)
        }
    }
}

/// Shown while an in-person meeting waits for its speaker models to download. It starts by itself when they're ready.
private struct SpeakerModelDownloadSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Getting the speaker models ready")
                .font(.headline)
            ProgressView(value: store.models.roomDownloadProgress)
            Text("\(Int(store.models.roomDownloadProgress * 100))% of about 430 MB. \u{201C}\(store.waitingToStart?.title ?? "Your meeting")\u{201D} starts as soon as the download finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Starting now records straight away. Speakers are still told apart after the meeting if the download has finished by then.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Don't Start") { store.cancelWaitingMeeting() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Now") { store.startWaitingMeetingNow() }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
