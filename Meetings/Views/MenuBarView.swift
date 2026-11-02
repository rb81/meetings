import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("Meetings")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Open Meetings")
            }

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

            Text("Start or stop from anywhere with ⌃⌥⌘M. Pause or resume with ⌃⌥⌘P.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 340)
        .background(Theme.canvas)
        .onChange(of: store.windowRequest) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
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
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(store.recorder.elapsed(at: context.date)))
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }

            HStack(spacing: 18) {
                if store.activeMeeting?.inPerson == true {
                    LevelBar(label: "Room", meter: store.levels, track: .mic, width: 56)
                } else {
                    LevelBar(label: "You", meter: store.levels, track: .mic, width: 56)
                    LevelBar(label: "Others", meter: store.levels, track: .system, width: 56)
                }
            }

            HStack(spacing: 10) {
                Button {
                    store.addBookmark()
                } label: {
                    Label("Flag", systemImage: "flag")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 36))

                Button {
                    store.togglePause()
                } label: {
                    Label(
                        store.recorder.isPaused ? "Resume" : "Pause",
                        systemImage: store.recorder.isPaused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 36))
                .disabled(store.isFinalizing)

                Button {
                    Task { await store.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
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
