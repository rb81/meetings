import SwiftUI

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Meetings")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    dismiss()
                    store.showMainWindow()
                } label: {
                    Label("Open Meetings", systemImage: "arrow.up.forward.app")
                        .fixedSize()
                }
                .buttonStyle(SecondaryButtonStyle(height: 30))
            }

            Divider()

            if store.recorder.isRecording {
                recordingSection
            } else {
                idleSection
            }

            if let version = store.updates.availableVersion {
                Link(destination: UpdateService.releasesURL) {
                    Label("Meetings \(version) available", systemImage: "arrow.down.circle")
                        .font(Theme.caption)
                }
            }

            VStack(spacing: 6) {
                shortcut("Start / stop", keys: "⌃⌥⌘M")
                shortcut("Pause / resume", keys: "⌃⌥⌘P")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 340)
        .background(Theme.canvas)
        .onChange(of: store.windowRequest) {
            dismiss()
        }
        .onChange(of: store.errorMessage) { _, message in
            if message != nil {
                store.showMainWindow()
            }
        }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys)
                .monospaced()
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(store.recorder.isPaused ? Theme.amber : Theme.red)
                        .frame(width: 8, height: 8)
                    Text(store.activeMeeting?.title ?? "Recording")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if store.recorder.isPaused {
                        Chip(text: "Paused", tint: Theme.amber)
                    } else if store.recorder.isMicMuted {
                        Chip(text: "Muted", symbol: "mic.slash.fill", tint: Theme.amber)
                    }
                }
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.clock(store.recorder.elapsed(at: context.date)))
                            .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    Spacer()
                    if store.activeMeeting?.inPerson != true {
                        MuteButton(size: 36)
                    }
                    Button {
                        store.addBookmark()
                    } label: {
                        Image(systemName: "flag")
                    }
                    .buttonStyle(IconButtonStyle(size: 36))
                    .help("Flag this moment")
                    .accessibilityLabel("Flag this moment")
                    .disabled(store.isFinalizing)
                }
            }

            HStack(spacing: 18) {
                if store.activeMeeting?.inPerson == true {
                    LevelBar(label: "Room", meter: store.levels, track: .mic, width: 56)
                } else {
                    LevelBar(label: "You", meter: store.levels, track: .mic, width: 56, muted: store.recorder.isMicMuted)
                    LevelBar(label: "Others", meter: store.levels, track: .system, width: 56)
                }
            }

            HStack(spacing: 10) {
                Button {
                    store.togglePause()
                } label: {
                    Label(
                        store.recorder.isPaused ? "Resume" : "Pause",
                        systemImage: store.recorder.isPaused ? "play.fill" : "pause.fill"
                    )
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 36))
                .disabled(store.isFinalizing)

                Button {
                    Task { await store.stopRecording() }
                } label: {
                    Label(store.isFinalizing ? "Saving..." : "Stop", systemImage: "stop.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(height: 36))
                .disabled(store.isFinalizing)
            }
        }
        .surface(padding: 16)
    }

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let next = store.calendar.events.first {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Next up")
                        Text(next.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                        Text(Format.range(next.start, next.end))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task {
                            await store.startRecording(
                                title: next.title,
                                joinURL: next.joinURL,
                                attendees: next.attendees,
                                inPerson: next.joinURL == nil
                            )
                        }
                    } label: {
                        Label(
                            next.joinURL == nil ? "Record In Person" : "Join & Record",
                            systemImage: next.joinURL == nil ? "person.2.fill" : "video.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 38))
                }
                .surface(padding: 16)
            } else {
                Text(store.calendar.isAuthorized ? "No upcoming meetings" : "Calendar not connected")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .surface(padding: 16)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await store.startQuickRecording() }
                } label: {
                    Label("Online", systemImage: "video.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 38))
                .help("Start an online meeting")

                Button {
                    Task { await store.startQuickRecording(inPerson: true) }
                } label: {
                    Label("In Person", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 38))
                .help("Start a meeting in the room")
            }
        }
    }
}
