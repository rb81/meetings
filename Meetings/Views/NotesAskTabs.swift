import SwiftUI

struct NotesTab: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    let file: TranscriptFile
    let isActive: Bool
    let audioSaved: Bool

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionLabel("Flagged moments")
                    Spacer()
                    if isActive {
                        Button {
                            store.addBookmark()
                        } label: {
                            Label("Flag now", systemImage: "flag")
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 30))
                    }
                }

                if meeting.bookmarks.isEmpty {
                    Text(isActive ? "Press ⌘B, or Flag now, to mark a moment you want to find later." : "Nothing was flagged in this meeting.")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(meeting.bookmarks) { bookmark in
                            BookmarkRow(meeting: meeting, bookmark: bookmark, file: file, canSeek: audioSaved && !isActive)
                        }
                    }
                }
            }
            .surface(padding: 24)

            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("My notes")
                TextEditor(text: $text)
                    .font(Theme.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(12)
                    .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .strokeBorder(Theme.stroke)
                    )
                    .onChange(of: text) {
                        store.setNotes(meeting, text: text)
                    }
                Text("Your notes are included when AI writes the summary.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            .surface(padding: 24)
        }
        .onAppear { text = meeting.notes }
    }
}

private struct BookmarkRow: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    let bookmark: Bookmark
    let file: TranscriptFile
    let canSeek: Bool

    @State private var note = ""

    private var line: (speaker: String?, text: String)? {
        guard let text = file.text(for: bookmark) else { return nil }
        return (file.segment(for: bookmark).map { file.label(for: $0) }, text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if let line {
                excerpt(line)
            }
        }
        .padding(.vertical, 6)
        .onAppear { note = bookmark.note }
    }

    private func excerpt(_ line: (speaker: String?, text: String)) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.amber.opacity(0.6))
                .frame(width: 3)
            Group {
                if let speaker = line.speaker {
                    Text("\(Text(speaker).fontWeight(.semibold)) \(line.text)")
                } else {
                    Text(line.text)
                }
            }
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .textSelection(.enabled)
        }
        .padding(.leading, 98)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                store.playback.load(meeting, dataFolder: store.settings.dataFolder)
                store.playback.play(from: max(0, bookmark.time - 3))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: canSeek ? "play.circle.fill" : "flag.fill")
                        .foregroundStyle(canSeek ? Theme.blue : Theme.amber)
                    Text(Format.clock(bookmark.time))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .frame(width: 84, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!canSeek)

            TextField("Add a note", text: $note)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .onSubmit { store.updateBookmark(meeting, id: bookmark.id, note: note) }

            Button(role: .destructive) {
                store.removeBookmark(meeting, id: bookmark.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(size: 28))
        }
    }
}

struct AskTab: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    let file: TranscriptFile

    private struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var failed = false
    }

    @State private var question = ""
    @State private var exchanges: [Exchange] = []
    @State private var asking = false

    private var canAsk: Bool { store.aiReady && !file.segments.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .foregroundStyle(.secondary)
                        TextField("Ask about this meeting…", text: $question)
                            .textFieldStyle(.plain)
                            .font(Theme.body)
                            .onSubmit(send)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .strokeBorder(Theme.stroke)
                    )

                    Button("Ask", action: send)
                        .buttonStyle(PrimaryButtonStyle(height: 38))
                        .disabled(!canAsk || asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let reason = store.aiBlockReason {
                    Label(reason, systemImage: "key")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.amber)
                } else if file.segments.isEmpty {
                    Text("There's no transcript to ask about yet.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Each question is answered from this meeting. \(store.aiDestination)")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .surface(padding: 20)

            ForEach(exchanges.reversed()) { exchange in
                VStack(alignment: .leading, spacing: 12) {
                    Text(exchange.question)
                        .font(Theme.heading)
                    if let answer = exchange.answer {
                        Text(answer)
                            .font(Theme.body)
                            .lineSpacing(4)
                            .foregroundStyle(exchange.failed ? Theme.red : .primary)
                            .textSelection(.enabled)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…")
                                .font(Theme.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .surface(padding: 24)
            }
        }
    }

    private func send() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !asking, !asked.isEmpty else { return }

        question = ""
        asking = true
        let exchange = Exchange(question: asked)
        exchanges.append(exchange)

        Task {
            var reply: String
            var failed = false
            do {
                reply = try await store.ask(meeting, question: asked)
            } catch {
                reply = error.localizedDescription
                failed = true
            }
            if let index = exchanges.firstIndex(where: { $0.id == exchange.id }) {
                exchanges[index].answer = reply
                exchanges[index].failed = failed
            }
            asking = false
        }
    }
}
