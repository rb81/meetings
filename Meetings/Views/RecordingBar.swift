import SwiftUI

private struct StopButtonStyle: ButtonStyle {
    var height: CGFloat = 38
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(Theme.red, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.red.opacity(0.35))
                .frame(width: 18, height: 18)
                .scaleEffect(pulsing ? 1.0 : 0.5)
                .opacity(pulsing ? 0 : 1)
            Circle()
                .fill(Theme.red)
                .frame(width: 9, height: 9)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

struct RecordingBar: View {
    @Environment(AppStore.self) private var store
    @State private var showingWarning = false
    @State private var flashed = false

    var body: some View {
        HStack(spacing: 16) {
            if store.recorder.isPaused {
                Circle()
                    .fill(Theme.amber)
                    .frame(width: 9, height: 9)
                    .frame(width: 18, height: 18)
            } else {
                PulsingDot()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(store.activeMeeting?.title ?? "Recording")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.clock(elapsed(at: context.date)))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                    Text("·")
                    Text(statusText)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let warning = store.recorder.warning {
                Button {
                    showingWarning.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(IconButtonStyle())
                .popover(isPresented: $showingWarning, arrowEdge: .top) {
                    Text(warning)
                        .font(Theme.body)
                        .padding(16)
                        .frame(width: 280, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                if store.activeMeeting?.inPerson == true {
                    LevelBar(label: "Room", meter: store.levels, track: .mic, width: 72)
                } else {
                    LevelBar(label: "You", meter: store.levels, track: .mic, width: 72)
                    LevelBar(label: "Others", meter: store.levels, track: .system, width: 72)
                }
            }

            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 1, height: 32)

            HStack(spacing: 6) {
                if let meeting = store.activeMeeting {
                    aiToggle(meeting)
                }

                flagButton

                Button {
                    store.togglePause()
                } label: {
                    Image(systemName: store.recorder.isPaused ? "play.fill" : "pause.fill")
                        .foregroundStyle(store.recorder.isPaused ? Theme.amber : .primary)
                }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(store.isFinalizing)
                .help(store.recorder.isPaused ? "Resume recording (⇧⌘P)" : "Pause recording (⇧⌘P)")
            }

            Button {
                Task { await store.stopRecording() }
            } label: {
                if store.isFinalizing {
                    ProgressView().controlSize(.small).tint(.white)
                        .frame(width: 52)
                } else {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
            .buttonStyle(StopButtonStyle())
            .keyboardShortcut(".", modifiers: .command)
            .disabled(store.isFinalizing)
            .help("Stop and save the meeting (⌘.)")
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.stroke)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    private var flagButton: some View {
        let count = store.activeMeeting?.bookmarks.count ?? 0

        return Button {
            store.addBookmark()
            flashed = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                flashed = false
            }
        } label: {
            Image(systemName: count > 0 ? "flag.fill" : "flag")
                .foregroundStyle(count > 0 ? Theme.amber : .secondary)
                .scaleEffect(flashed ? 1.3 : 1)
            .animation(.spring(duration: 0.25), value: flashed)
        }
        .buttonStyle(IconButtonStyle())
        .keyboardShortcut("b", modifiers: .command)
        .help(count > 0 ? "Flag this moment (⌘B) · \(count) flagged so far" : "Flag this moment (⌘B)")
    }

    private func aiToggle(_ meeting: Meeting) -> some View {
        Button {
            store.setAINotes(meeting, enabled: !meeting.aiNotes)
        } label: {
            Label("AI notes", systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(meeting.aiNotes ? Theme.blue : .secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(meeting.aiNotes ? Theme.blue.opacity(0.16) : Theme.raised.opacity(0.7))
                )
        }
        .buttonStyle(.plain)
        .disabled(!store.aiReady)
        .help(store.aiReady ? "Write notes with your AI provider when the meeting ends" : (store.aiBlockReason ?? ""))
    }

    private var statusText: String {
        if store.isFinalizing { return "Finishing transcript…" }
        if store.recorder.isPaused { return "Paused" }
        guard store.isTranscribingLive else { return "Audio only" }
        return store.liveSpeakersActive ? "Live transcription and speakers" : "Live transcription on"
    }

    private func elapsed(at date: Date) -> TimeInterval {
        store.recorder.elapsed(at: date)
    }
}
