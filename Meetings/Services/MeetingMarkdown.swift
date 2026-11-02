import Foundation

enum MeetingMarkdown {
    static func build(meeting: Meeting, transcript: TranscriptFile, notes: MeetingNotes?) -> String {
        var lines = ["# \(meeting.title)", ""]
        lines.append("*\(Format.day(meeting.startedAt)) · \(Format.range(meeting.startedAt, meeting.endDate))*")
        if !meeting.attendees.isEmpty {
            lines.append("")
            lines.append("**Attendees:** \(meeting.attendees.joined(separator: ", "))")
        }

        if let notes {
            lines += ["", "## Summary", "", notes.summary]
            if !notes.decisions.isEmpty {
                lines += ["", "## Decisions", ""] + notes.decisions.map { "- \($0)" }
            }
            if !notes.actionItems.isEmpty {
                lines += ["", "## Action items", ""]
                lines += notes.actionItems.map { item in
                    var line = "- [ ] \(item.task)"
                    if let owner = item.owner, !owner.isEmpty { line += " (\(owner))" }
                    if let due = item.due, !due.isEmpty { line += " — \(due)" }
                    return line
                }
            }
        }

        if !meeting.notes.isEmpty {
            lines += ["", "## My notes", "", meeting.notes]
        }
        if !meeting.bookmarks.isEmpty {
            lines += ["", "## Flagged moments", ""]
            lines += meeting.bookmarks.map { bookmark in
                var line = "- \(Format.clock(bookmark.time))"
                if !bookmark.note.isEmpty { line += " \(bookmark.note)" }
                if let segment = transcript.segment(for: bookmark) {
                    line += " — \(transcript.label(for: segment)): \"\(segment.displayText)\""
                } else if let excerpt = bookmark.excerpt {
                    line += " — \"\(excerpt)\""
                }
                return line
            }
        }

        if !transcript.segments.isEmpty {
            lines += ["", "## Transcript", ""]
            lines += transcript.segments.map { segment in
                "**\(transcript.label(for: segment))** (\(Format.clock(segment.start))): \(segment.displayText)"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
