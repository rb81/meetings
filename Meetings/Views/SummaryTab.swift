import SwiftUI

struct SummaryTab: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    let notes: MeetingNotes?
    let file: TranscriptFile

    @State private var reminderMessage: String?

    private var busy: Bool { store.processing[meeting.id] != nil || meeting.id == store.activeMeetingID }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            aiCard

            if let notes {
                notesCard(notes)
                if !notes.decisions.isEmpty {
                    decisionsCard(notes)
                }
                if !notes.actionItems.isEmpty {
                    actionsCard(notes)
                }
                Text("Written by \(notes.model) · \(notes.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else if store.aiReady, !file.segments.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.violet)
                    Text("No notes yet")
                        .font(Theme.heading)
                    Text("Write a summary, decisions, and action items from this transcript.")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .surface(padding: 32)
            }
        }
    }

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("AI notes for this meeting")
                        .font(Theme.heading)
                    Text("When the meeting ends, your AI provider cleans up the transcript and writes a summary.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Toggle("", isOn: Binding(
                    get: { meeting.aiNotes },
                    set: { store.setAINotes(meeting, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!store.aiReady)
            }

            if let reason = store.aiBlockReason {
                HStack {
                    Label(reason, systemImage: "key")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.amber)
                    Spacer()
                    SettingsLink { Text("Open Settings") }
                        .buttonStyle(SecondaryButtonStyle(height: 30))
                }
            } else {
                HStack(spacing: 10) {
                    Button(notes == nil ? "Write Notes" : "Rewrite Notes") {
                        Task { await store.generateNotes(meeting) }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 32))

                    Spacer()

                    Text(store.aiDestination)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(busy || file.segments.isEmpty)
            }
        }
        .surface()
    }

    private func notesCard(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Summary")
            Text(notes.summary)
                .font(Theme.body)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .surface(padding: 24)
    }

    private func decisionsCard(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Decisions")
            ForEach(notes.decisions, id: \.self) { decision in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.green)
                    Text(decision)
                        .font(Theme.body)
                        .lineSpacing(3)
                }
            }
        }
        .surface(padding: 24)
    }

    private func actionsCard(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Action items")
                Spacer()
                Button {
                    Task { reminderMessage = await store.addToReminders(meeting, items: notes.actionItems) }
                } label: {
                    Label("Add to Reminders", systemImage: "checklist")
                }
                .buttonStyle(SecondaryButtonStyle(height: 30))
            }

            ForEach(notes.actionItems) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.task)
                            .font(Theme.body)
                        let detail = [item.owner, item.due].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail)
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let reminderMessage {
                Text(reminderMessage)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .surface(padding: 24)
    }
}
