import Foundation

enum RetentionService {
    /// Deletes audio that the policy no longer allows. Meetings listed in `excluding` are still being processed.
    static func apply(
        _ policy: AudioRetention,
        in dataFolder: URL,
        meetings: [Meeting],
        excluding busy: Set<UUID> = [],
        now: Date = .now
    ) {
        for meeting in meetings
        where meeting.endedAt != nil
            && !busy.contains(meeting.id)
            && MeetingStore.hasAudio(meeting, in: dataFolder) {
            guard shouldDeleteAudio(for: meeting, policy: policy, in: dataFolder, now: now) else { continue }
            try? MeetingStore.deleteAudio(meeting, in: dataFolder)
        }
    }

    private static func shouldDeleteAudio(
        for meeting: Meeting,
        policy: AudioRetention,
        in dataFolder: URL,
        now: Date
    ) -> Bool {
        switch policy {
        case .never:
            return false
        case .afterTranscription:
            return MeetingStore.hasTranscript(meeting, in: dataFolder)
        case .afterOneDay, .afterSevenDays, .afterThirtyDays:
            guard let maxAge = policy.maxAge else { return false }
            return now.timeIntervalSince(meeting.endDate) >= maxAge
        }
    }
}
